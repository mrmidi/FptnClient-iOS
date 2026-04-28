import Foundation
import Combine
import NetworkExtension
import FptnSharedCore

@MainActor
final class MacVPNService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var statusText = "Disconnected"
    @Published private(set) var errorText: String?

    private var manager: NETunnelProviderManager?
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var requestedLogLevel: String = "warning"
    private let timeoutSeconds = 10

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func syncWithSystem() {
        Task { @MainActor in
            do {
                guard let loadedManager = try await loadExistingManager() else {
                    self.manager = nil
                    statusText = "Disconnected"
                    isConnected = false
                    return
                }
                self.manager = loadedManager
                observe(loadedManager)
                syncStatus()
            } catch {
                errorText = "Failed to load VPN preferences: \(error.localizedDescription)"
            }
        }
    }

    func connect(
        tokenPayload: MacTokenPayload,
        server: MacVPNServer,
        sni: String,
        logLevel: String = "warning"
    ) {
        guard !isConnecting else { return }
        guard !tokenPayload.username.isEmpty else {
            errorText = "Token username is required"
            return
        }

        isConnecting = true
        errorText = nil
        requestedLogLevel = logLevel
        statusText = "Preparing tunnel..."

        Task { @MainActor in
            defer { isConnecting = false }
            do {
                statusText = "Authenticating..."
                let accessToken = try loginToServer(
                    server: server,
                    sni: sni,
                    username: tokenPayload.username,
                    password: tokenPayload.password
                )
                let dns = try fetchDNSInfo(server: server, sni: sni, accessToken: accessToken)

                let manager = try await ensureManager()
                let payload = MacTunnelProviderPayload(
                    server: server.host,
                    port: server.port,
                    accessToken: accessToken,
                    dnsIPv4: dns.dnsIPv4,
                    dnsIPv6: dns.dnsIPv6,
                    sni: sni,
                    md5Fingerprint: server.md5_fingerprint,
                    logLevel: logLevel
                )

                let proto = NETunnelProviderProtocol()
                proto.serverAddress = "Fptn-macOS"
                proto.providerBundleIdentifier = "net.mrmidi.Fptn-macOS.Fptn-macOS-Tunnel"
                proto.providerConfiguration = payload.asDictionary()

                manager.protocolConfiguration = proto
                manager.localizedDescription = "FPTN macOS"
                manager.isEnabled = true

                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()

                self.manager = manager
                observe(manager)

                switch manager.connection.status {
                case .connected, .connecting, .reasserting:
                    break
                default:
                    try manager.connection.startVPNTunnel()
                }

                statusText = "Connecting..."
            } catch {
                let nsError = error as NSError
                errorText = "Connect failed: \(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]"
                statusText = "Disconnected"
                isConnected = false
            }
        }
    }

    private func loginToServer(
        server: MacVPNServer,
        sni: String,
        username: String,
        password: String
    ) throws -> String {
        let client = MacApiClientBridge(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint
        )

        let body: [String: String] = [
            "username": username,
            "password": password
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode login payload"
            ])
        }

        let response = client.post(path: "/api/v1/login", body: bodyString, timeout: timeoutSeconds)
        let responseCode = response.code
        guard responseCode == 200 else {
            let codeDescription = String(responseCode)
            let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Login failed (HTTP \(codeDescription))\(serverError.map { ": \($0)" } ?? "")"
            ])
        }

        guard let responseBody = response.body,
              let bodyData = responseBody.data(using: .utf8) else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing login response body"
            ])
        }

        let jsonObject = try JSONSerialization.jsonObject(with: bodyData)
        guard let json = jsonObject as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Login returned empty access_token"
            ])
        }
        return accessToken
    }

    private func fetchDNSInfo(server: MacVPNServer, sni: String, accessToken: String) throws -> MacDNSResolved {
        let client = MacApiClientBridge(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint
        )
        _ = accessToken

        let response = client.get(path: "/api/v1/dns", timeout: timeoutSeconds)
        let responseCode = response.code
        guard responseCode == 200 else {
            let codeDescription = String(responseCode)
            let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DNS fetch failed (HTTP \(codeDescription))\(serverError.map { ": \($0)" } ?? "")"
            ])
        }

        guard let responseBody = response.body,
              let bodyData = responseBody.data(using: .utf8) else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing DNS response body"
            ])
        }

        let jsonObject = try JSONSerialization.jsonObject(with: bodyData)
        guard let json = jsonObject as? [String: Any] else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DNS response is not a JSON object"
            ])
        }

        let dnsIPv4 = (json["dns"] as? String) ?? (json["dnsIPv4"] as? String)
        let dnsIPv6 = (json["dns_ipv6"] as? String) ?? (json["dnsIPv6"] as? String) ?? "fd00::1"

        guard let dnsIPv4, !dnsIPv4.isEmpty else {
            throw NSError(domain: "MacVPNService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DNS response is incomplete"
            ])
        }

        return MacDNSResolved(
            dnsIPv4: dnsIPv4,
            dnsIPv6: dnsIPv6
        )
    }

    func disconnect() {
        errorText = nil
        statusText = "Disconnecting..."
        guard let session = manager?.connection as? NETunnelProviderSession else {
            manager?.connection.stopVPNTunnel()
            syncStatus()
            return
        }

        let message = MacTunnelControlMessage(
            action: .prepareStop,
            initiator: "app_disconnect"
        )
        guard let payload = try? JSONEncoder().encode(message) else {
            manager?.connection.stopVPNTunnel()
            syncStatus()
            return
        }

        do {
            try session.sendProviderMessage(payload) { [weak self] responseData in
                Task { @MainActor in
                    if responseData == nil {
                        self?.errorText = "Tunnel did not acknowledge disconnect request"
                    }
                    self?.manager?.connection.stopVPNTunnel()
                    self?.syncStatus()
                }
            }
        } catch {
            errorText = "Tunnel disconnect message failed: \(error.localizedDescription)"
            manager?.connection.stopVPNTunnel()
            syncStatus()
        }
    }

    func pingTunnel() {
        sendControlMessage(.init(action: .ping)) { [weak self] response in
            guard response.ok else {
                self?.errorText = "Tunnel ping failed: \(response.message)"
                return
            }
            self?.statusText = response.message
        }
    }

    private func observe(_ manager: NETunnelProviderManager) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.syncStatus()
            }
        }
    }

    private func syncStatus() {
        guard let status = manager?.connection.status else {
            isConnected = false
            statusText = "Disconnected"
            return
        }

        switch status {
        case .connected:
            isConnected = true
            statusText = "Connected"
            sendControlMessage(.init(action: .setLogLevel, logLevel: requestedLogLevel)) { _ in }
        case .connecting, .reasserting:
            isConnected = false
            statusText = "Connecting..."
        case .disconnecting:
            isConnected = false
            statusText = "Disconnecting..."
        case .disconnected, .invalid:
            isConnected = false
            statusText = "Disconnected"
        @unknown default:
            isConnected = false
            statusText = "Unknown"
        }
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }
        if let existing = try await loadExistingManager() {
            self.manager = existing
            return existing
        }
        let created = NETunnelProviderManager()
        self.manager = created
        return created
    }

    private func sendControlMessage(
        _ message: MacTunnelControlMessage,
        completion: @escaping @MainActor (MacTunnelControlResponse) -> Void
    ) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            errorText = "Tunnel session is unavailable"
            return
        }
        guard let payload = try? JSONEncoder().encode(message) else {
            errorText = "Failed to encode tunnel message"
            return
        }

        do {
            try session.sendProviderMessage(payload) { [weak self] responseData in
                guard let self else { return }
                Task { @MainActor in
                    guard let responseData,
                          let response = try? JSONDecoder().decode(MacTunnelControlResponse.self, from: responseData) else {
                        self.errorText = "Invalid tunnel response"
                        return
                    }
                    completion(response)
                }
            }
        } catch {
            errorText = "Tunnel message failed: \(error.localizedDescription)"
        }
    }

}

private struct MacDNSResolved {
    let dnsIPv4: String
    let dnsIPv6: String
}

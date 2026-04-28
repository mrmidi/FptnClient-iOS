import Foundation
import NetworkExtension
import Observation
import FptnSharedCore

@MainActor
@Observable
final class TvVPNService {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var statusText = "Disconnected"
    private(set) var errorText: String?

    private var manager: NETunnelProviderManager?
    @ObservationIgnored
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var requestedLogLevel: SharedLogLevel = .warning
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
                    manager = nil
                    isConnected = false
                    statusText = "Disconnected"
                    return
                }
                manager = loadedManager
                observe(loadedManager)
                syncStatus()
            } catch {
                errorText = "Failed to load VPN preferences: \(error.localizedDescription)"
            }
        }
    }

    func connect(tokenPayload: TvTokenPayload, server: TvVPNServer, sni: String = "google.com", logLevel: SharedLogLevel = .warning) {
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
                let accessToken = try await loginToServer(
                    server: server,
                    sni: sni,
                    username: tokenPayload.username,
                    password: tokenPayload.password
                )

                let dns = try await fetchDNSInfo(server: server, sni: sni, accessToken: accessToken)
                let manager = try await ensureManager()

                let payload = TunnelProviderPayload(
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
                proto.serverAddress = "Fptn-tvOS"
                proto.providerBundleIdentifier = "net.mrmidi.Fptn-macOS.Fptn-tvOS.Fptn-tvOS-Tunnel"
                proto.providerConfiguration = payload.asDictionary()

                manager.protocolConfiguration = proto
                manager.localizedDescription = "FPTN tvOS"
                manager.isEnabled = true

                statusText = "Saving VPN profile..."
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

    func disconnect() {
        errorText = nil
        statusText = "Disconnecting..."
        manager?.connection.stopVPNTunnel()
        syncStatus()
    }

    func pingTunnel() {
        sendControlMessage(TunnelControlMessage(action: .ping)) { [weak self] response in
            guard response.ok else {
                self?.errorText = "Tunnel ping failed: \(response.message)"
                return
            }
            self?.statusText = response.message
        }
    }

    func setTunnelLogLevel(_ level: SharedLogLevel) {
        requestedLogLevel = level
        sendControlMessage(TunnelControlMessage(action: .setLogLevel, logLevel: level)) { _ in }
    }

    private func loginToServer(server: TvVPNServer, sni: String, username: String, password: String) async throws -> String {
        let client = TvApiClientBridge(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint
        )

        let body: [String: String] = ["username": username, "password": password]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode login payload"])
        }

        let response = client.post(path: "/api/v1/login", body: bodyString, timeout: timeoutSeconds)
        let responseCode = response.code
        guard responseCode == 200 else {
            let codeDescription = String(responseCode)
            let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Login failed (HTTP \(codeDescription))\(serverError.map { ": \($0)" } ?? "")"])
        }

        guard let responseBody = response.body,
              let responseData = responseBody.data(using: .utf8) else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing login response body"])
        }

        let jsonObject = try JSONSerialization.jsonObject(with: responseData)
        guard let json = jsonObject as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Login returned empty access_token"])
        }

        return accessToken
    }

    private func fetchDNSInfo(server: TvVPNServer, sni: String, accessToken: String) async throws -> TvDNSResolved {
        let client = TvApiClientBridge(
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
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "DNS fetch failed (HTTP \(codeDescription))\(serverError.map { ": \($0)" } ?? "")"])
        }

        guard let responseBody = response.body,
              let bodyData = responseBody.data(using: .utf8) else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing DNS response body"])
        }

        let jsonObject = try JSONSerialization.jsonObject(with: bodyData)
        guard let json = jsonObject as? [String: Any] else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "DNS response is not a JSON object"])
        }

        let dnsIPv4 = (json["dns"] as? String) ?? (json["dnsIPv4"] as? String)
        let dnsIPv6 = (json["dns_ipv6"] as? String) ?? (json["dnsIPv6"] as? String) ?? "fd00::1"
        guard let dnsIPv4, !dnsIPv4.isEmpty else {
            throw NSError(domain: "TvVPNService", code: -1, userInfo: [NSLocalizedDescriptionKey: "DNS response is incomplete"])
        }

        return TvDNSResolved(dnsIPv4: dnsIPv4, dnsIPv6: dnsIPv6)
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
            setTunnelLogLevel(requestedLogLevel)
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
        _ message: TunnelControlMessage,
        completion: @escaping @MainActor (TunnelControlResponse) -> Void
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
                          let response = try? JSONDecoder().decode(TunnelControlResponse.self, from: responseData) else {
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

private struct TvDNSResolved {
    let dnsIPv4: String
    let dnsIPv6: String
}

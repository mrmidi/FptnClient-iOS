/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine
@preconcurrency import NetworkExtension

// NETunnelProviderManager is documented to be used on the main thread but
// Apple hasn't added Sendable conformance to it yet. This box lets us
// carry it through assumeIsolated's @Sendable closure without unsafely
// suppressing Sendable checking across the whole type.
private struct NEManagerBox: @unchecked Sendable {
    let manager: NETunnelProviderManager
    init(_ manager: NETunnelProviderManager) { self.manager = manager }
}

@MainActor
class VPNService: ObservableObject {
    @Published var connection = VPNConnection()

    private var timer: Timer?
    private var speedTimer: Timer?
    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?

    private let tokenService = TokenService.shared

    // MARK: - Public

    func connect() {
        Task {
            await performConnect()
        }
    }

    func disconnect() {
        packetTunnelProvider?.connection.stopVPNTunnel()
        packetTunnelProvider = nil

        if let observer = tunnelStatusObserver {
            NotificationCenter.default.removeObserver(observer)
            tunnelStatusObserver = nil
        }

        connection.isConnected = false
        stopTimer()
        stopSpeedMonitoring()
    }

    // MARK: - Private connect flow

    private func performConnect() async {
        // Resolve server
        let servers = await tokenService.getServers()
        guard let server = servers.first else {
            logger.warning("No servers available — cannot connect")
            return
        }

        connection.selectedServer = server

        guard let tokenData = await tokenService.getTokenData() else {
            logger.error("No token data available")
            return
        }

        // Login
        let accessTokenResult = await loginToServer(
            server: server,
            username: tokenData.username,
            password: tokenData.password
        )
        guard case .success(let accessToken) = accessTokenResult else {
            if case .failure(let error) = accessTokenResult {
                logger.error("Login error: \(error.localizedDescription)")
            }
            return
        }

        // DNS
        let dnsResult = await getDNSInfo(server: server, accessToken: accessToken)
        guard case .success(let (dnsIPv4, dnsIPv6)) = dnsResult else {
            if case .failure(let error) = dnsResult {
                logger.error("DNS info error: \(error.localizedDescription)")
            }
            return
        }

        // Save config and launch the PacketTunnelProvider extension.
        // The extension owns the WebSocket and the TUN interface — the app
        // process does not run a second WebSocket connection.
        let vpnResult = await configureAndStartVPN(
            server: server,
            accessToken: accessToken,
            dnsIPv4: dnsIPv4,
            dnsIPv6: dnsIPv6
        )
        if case .failure(let error) = vpnResult {
            logger.error("VPN configuration error: \(error.localizedDescription)")
        }
    }

    // MARK: - Login

    private func loginToServer(
        server: VPNServer,
        username: String,
        password: String
    ) async -> Result<String, Error> {
        let httpsClient = HttpsClientSwift(
            host: server.host,
            port: server.port,
            sni: server.host,
            md5Fingerprint: server.md5_fingerprint
        )

        let requestBody = """
        {
            "username": "\(username)",
            "password": "\(password)"
        }
        """

        let response = httpsClient.post(path: "/api/v1/login", body: requestBody, timeout: 10)

        guard (response["code"] as? Int32) == 200 else {
            let errorMessage = response["error"] as? String ?? "Unknown error"
            return .failure(NSError(
                domain: "VPNService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }

        guard let body = response["body"] as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return .failure(NSError(
                domain: "VPNService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Access token not found"]
            ))
        }

        logger.debug("Login successful, token: \(hideCred(accessToken))")
        return .success(accessToken)
    }

    // MARK: - DNS

    private func getDNSInfo(
        server: VPNServer,
        accessToken: String
    ) async -> Result<(String, String), Error> {
        let httpsClient = HttpsClientSwift(
            host: server.host,
            port: server.port,
            sni: server.host,
            md5Fingerprint: server.md5_fingerprint
        )

        let response = httpsClient.get(path: "/api/v1/dns", timeout: 10)

        guard (response["code"] as? Int32) == 200 else {
            let errorMessage = response["error"] as? String ?? "Unknown error"
            return .failure(NSError(
                domain: "VPNService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }

        guard let body = response["body"] as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dnsIPv4 = json["dns"] as? String else {
            return .failure(NSError(
                domain: "VPNService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "DNS info not found"]
            ))
        }

        let dnsIPv6 = json["dns_ipv6"] as? String ?? "fd00::1"
        logger.debug("DNS IPv4: \(dnsIPv4)  IPv6: \(dnsIPv6)")
        return .success((dnsIPv4, dnsIPv6))
    }

    // MARK: - VPN tunnel configuration

    private func configureAndStartVPN(
        server: VPNServer,
        accessToken: String,
        dnsIPv4: String,
        dnsIPv6: String
    ) async -> Result<Void, Error> {
        return await withCheckedContinuation { continuation in
            // Reuse the existing manager when one is already installed — creating a
            // fresh NETunnelProviderManager() on every connect would accumulate
            // duplicate VPN profiles in Settings.
            NETunnelProviderManager.loadAllFromPreferences { [weak self] existing, error in
                guard let self else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "VPNService",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "VPNService deallocated"]
                    )))
                    return
                }

                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }

                let manager = existing?.first ?? NETunnelProviderManager()

                let config = NETunnelProviderProtocol()
                config.serverAddress = server.host
#if os(iOS)
                config.providerBundleIdentifier = "net.mrmidi.FptnVPN.FptnVPNTunnel"
#else
                config.providerBundleIdentifier = "org.fptn.FptnVPN.mac.extension"
#endif
                config.providerConfiguration = [
                    "server": server.host,
                    "port": server.port,
                    "accessToken": accessToken,
                    "dnsIPv4": dnsIPv4,
                    "dnsIPv6": dnsIPv6,
                    "sni": server.host,
                    "md5Fingerprint": server.md5_fingerprint
                ]

                manager.protocolConfiguration = config
                manager.localizedDescription = "FPTN"
                manager.isEnabled = true

                let box = NEManagerBox(manager)

                box.manager.saveToPreferences { error in
                    if let error {
                        logger.error("Save preferences error: \(error.localizedDescription)")
                        continuation.resume(returning: .failure(error))
                        return
                    }

                    logger.info("VPN configuration saved successfully")

                    box.manager.loadFromPreferences { [weak self] error in
                        if let error {
                            logger.error("Load preferences error: \(error.localizedDescription)")
                            continuation.resume(returning: .failure(error))
                            return
                        }

                        // Start the PacketTunnelProvider extension. This is what
                        // configures the TUN interface and routes all device traffic
                        // through the VPN. Without this call the OS never touches the
                        // tunnel and traffic continues over the regular network.
                        do {
                            try box.manager.connection.startVPNTunnel()
                            logger.info("VPN tunnel start requested")
                        } catch {
                            logger.error("startVPNTunnel failed: \(error.localizedDescription)")
                            continuation.resume(returning: .failure(error))
                            return
                        }

                        MainActor.assumeIsolated { [weak self] in
                            self?.packetTunnelProvider = box.manager
                            self?.observeTunnelStatus(box.manager)
                            continuation.resume(returning: .success(()))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tunnel status observation

    /// Observe NEVPNStatusDidChange so isConnected tracks the real tunnel state,
    /// not just whether a WebSocket started in the app process.
    private func observeTunnelStatus(_ manager: NETunnelProviderManager) {
        if let previous = tunnelStatusObserver {
            NotificationCenter.default.removeObserver(previous)
        }
        tunnelStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncTunnelStatus()
            }
        }
    }

    private func syncTunnelStatus() {
        guard let status = packetTunnelProvider?.connection.status else { return }
        logger.debug("Tunnel status changed: \(status.rawValue)")
        switch status {
        case .connected:
            connection.isConnected = true
            startTimer()
            startRealSpeedMonitoring()
        case .disconnected, .invalid:
            if connection.isConnected {
                connection.isConnected = false
                stopTimer()
                stopSpeedMonitoring()
            }
        default:
            break
        }
    }

    // MARK: - Timers

    private func startRealSpeedMonitoring() {
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connection.isConnected else { return }
                // TODO(phase3): replace with real stats from the websocket client
                self.connection.downloadSpeed = Double.random(in: 5...15)
                self.connection.uploadSpeed = Double.random(in: 2...8)
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.connection.connectionTime += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        connection.connectionTime = 0
    }

    private func stopSpeedMonitoring() {
        speedTimer?.invalidate()
        speedTimer = nil
        connection.downloadSpeed = 0
        connection.uploadSpeed = 0
    }

    // MARK: - Formatting

    func formatConnectionTime() -> String {
        let hours = Int(connection.connectionTime) / 3600
        let minutes = (Int(connection.connectionTime) % 3600) / 60
        let seconds = Int(connection.connectionTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func formatSpeed(_ speed: Double) -> String {
        if speed < 1000 {
            return String(format: "%.1f Kbps", speed)
        } else {
            return String(format: "%.1f Mbps", speed / 1000)
        }
    }
}

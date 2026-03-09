/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine
@preconcurrency import NetworkExtension

private struct TunnelControlMessage: Codable {
    let action: String
    let logLevel: String?
}

@MainActor
class VPNService: ObservableObject {
    @Published var connection = VPNConnection()

    private var timer: Timer?
    private var speedTimer: Timer?
    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?

    // Auto-reconnect state
    private var reconnectTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false

    private let tokenService = TokenService.shared
    private let serverSelectionService = ServerSelectionService.shared

    // MARK: - Public

    /// Load the existing tunnel manager from system preferences and sync UI state.
    /// Call on appear and when returning to foreground so the app reflects VPN
    /// status changes made from Control Center or Settings.
    func syncWithSystem() {
        Task { @MainActor in
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                guard let manager = managers.first else { return }
                self.packetTunnelProvider = manager
                self.observeTunnelStatus(manager)
                self.syncTunnelStatus()
            } catch {
                logger.warning("syncWithSystem: failed to load preferences: \(error.localizedDescription)")
            }
        }
    }

    func connect() {
        userInitiatedDisconnect = false
        Task {
            await performConnect()
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil

        packetTunnelProvider?.connection.stopVPNTunnel()
        packetTunnelProvider = nil

        if let observer = tunnelStatusObserver {
            NotificationCenter.default.removeObserver(observer)
            tunnelStatusObserver = nil
        }

        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.errorMessage = nil
        stopTimer()
        stopSpeedMonitoring()
    }

    static func pushLogLevelToActiveTunnel(_ level: LogLevel) async {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                guard error == nil else {
                    logger.error("Failed to load tunnel managers for log-level sync")
                    continuation.resume()
                    return
                }

                guard let manager = managers?.first,
                      let session = manager.connection as? NETunnelProviderSession,
                      manager.connection.status == .connected || manager.connection.status == .connecting else {
                    continuation.resume()
                    return
                }

                let message = TunnelControlMessage(action: "set_log_level", logLevel: level.rawValue)
                guard let data = try? JSONEncoder().encode(message) else {
                    continuation.resume()
                    return
                }

                do {
                    try session.sendProviderMessage(data) { _ in
                        continuation.resume()
                    }
                } catch {
                    logger.warning("Failed to send log-level update to tunnel: \(error.localizedDescription)")
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Private connect flow

    private func performConnect() async {
        connection.isConnecting = true
        connection.errorMessage = nil
        defer { connection.isConnecting = false }

        // Resolve server — honour manual selection if set, fall back to auto (first).
        let server: VPNServer
        switch connection.connectionMode {
        case .manual(let chosen):
            server = chosen
        case .auto:
            let servers = await tokenService.getServers()
            guard !servers.isEmpty else {
                connection.errorMessage = "No servers available"
                logger.warning("No servers available — cannot connect")
                return
            }

            let selection = await serverSelectionService.refreshBestReachableServerForAutoMode()
            connection.warningMessage = await serverSelectionService.warningMessage(for: selection.rows)

            guard let best = selection.selectedServer else {
                connection.errorMessage = "No reachable servers available right now"
                logger.warning("Auto mode: no reachable servers available")
                return
            }
            server = best
        }

        connection.selectedServer = server

        guard let tokenData = await tokenService.getTokenData() else {
            connection.errorMessage = "No token data available"
            logger.error("No token data available")
            return
        }

        let settings = SettingsService.shared
        let sni = settings.sni
        let strategy = settings.bypassMethod.rawValue

        // Login
        let accessTokenResult = await loginToServer(
            server: server,
            username: tokenData.username,
            password: tokenData.password,
            sni: sni,
            censorshipStrategy: strategy
        )
        guard case .success(let accessToken) = accessTokenResult else {
            if case .failure(let error) = accessTokenResult {
                connection.errorMessage = "Login failed: \(error.localizedDescription)"
                logger.error("Login error: \(error.localizedDescription)")
            }
            return
        }

        // DNS
        let dnsResult = await getDNSInfo(server: server, accessToken: accessToken, sni: sni, censorshipStrategy: strategy)
        guard case .success(let (dnsIPv4, dnsIPv6)) = dnsResult else {
            if case .failure(let error) = dnsResult {
                connection.errorMessage = "DNS lookup failed: \(error.localizedDescription)"
                logger.error("DNS info error: \(error.localizedDescription)")
            }
            return
        }

        // Save config and launch the PacketTunnelProvider extension.
        let vpnResult = await configureAndStartVPN(
            server: server,
            accessToken: accessToken,
            dnsIPv4: dnsIPv4,
            dnsIPv6: dnsIPv6,
            sni: sni,
            bypassMethod: strategy
        )
        switch vpnResult {
        case .success(let manager):
            self.packetTunnelProvider = manager
            self.observeTunnelStatus(manager)
        case .failure(let error):
            connection.errorMessage = "VPN configuration failed: \(error.localizedDescription)"
            logger.error("VPN configuration error: \(error.localizedDescription)")
        }
    }

    func refreshCachedServerWarning() {
        Task { @MainActor in
            connection.warningMessage = await serverSelectionService.cachedWarningMessage()
        }
    }

    // MARK: - Login

    nonisolated private func loginToServer(
        server: VPNServer,
        username: String,
        password: String,
        sni: String,
        censorshipStrategy: String
    ) async -> Result<String, Error> {
        logger.info("Login request start host=\(server.host) port=\(server.port) sni=\(sni) strategy=\(censorshipStrategy)")

        let httpsClient = HttpsClientSwift(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint,
            censorshipStrategy: censorshipStrategy
        )

        let requestBody = """
        {
            "username": "\(username)",
            "password": "\(password)"
        }
        """

        let response = httpsClient.post(path: "/api/v1/login", body: requestBody, timeout: 10)
        let responseCode = response["code"] as? Int32 ?? -1

        guard responseCode == 200 else {
            let errorMessage = response["error"] as? String ?? "Unknown error"
            logger.error("Login request failed host=\(server.host) port=\(server.port) sni=\(sni) code=\(responseCode) error=\(errorMessage)")
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
            logger.error("Login response parse failed host=\(server.host) port=\(server.port) code=\(responseCode)")
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

    nonisolated private func getDNSInfo(
        server: VPNServer,
        accessToken: String,
        sni: String,
        censorshipStrategy: String
    ) async -> Result<(String, String), Error> {
        logger.info("DNS request start host=\(server.host) port=\(server.port) sni=\(sni) strategy=\(censorshipStrategy)")

        let httpsClient = HttpsClientSwift(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint,
            censorshipStrategy: censorshipStrategy
        )

        let response = httpsClient.get(path: "/api/v1/dns", timeout: 10)
        let responseCode = response["code"] as? Int32 ?? -1

        guard responseCode == 200 else {
            let errorMessage = response["error"] as? String ?? "Unknown error"
            logger.error("DNS request failed host=\(server.host) port=\(server.port) sni=\(sni) code=\(responseCode) error=\(errorMessage)")
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
            logger.error("DNS response parse failed host=\(server.host) port=\(server.port) code=\(responseCode)")
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
        dnsIPv6: String,
        sni: String,
        bypassMethod: String
    ) async -> Result<NETunnelProviderManager, Error> {
        return await withCheckedContinuation { continuation in
            // Reuse the existing manager when one is already installed — creating a
            // fresh NETunnelProviderManager() on every connect would accumulate
            // duplicate VPN profiles in Settings.
            NETunnelProviderManager.loadAllFromPreferences { existing, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }

                let manager = existing?.first ?? NETunnelProviderManager()

                let config = NETunnelProviderProtocol()
                config.serverAddress = "FptnVPN"
#if os(iOS)
                config.providerBundleIdentifier = "net.mrmidi.FptnVPN.FptnVPNTunnel"
#else
                config.providerBundleIdentifier = "org.fptn.FptnVPN.mac.extension"
#endif

                let appFilter = AppFilterService.shared
                config.providerConfiguration = [
                    "server": server.host,
                    "port": server.port,
                    "accessToken": accessToken,
                    "dnsIPv4": dnsIPv4,
                    "dnsIPv6": dnsIPv6,
                    "sni": sni,
                    "logLevel": SettingsService.shared.logLevel.rawValue,
                    "md5Fingerprint": server.md5_fingerprint,
                    "bypassMethod": bypassMethod,
                    "websocketIdleTimeoutSeconds": SettingsService.shared.websocketIdleTimeoutSeconds,
                    "websocketReconnectAttempts": SettingsService.shared.websocketReconnectAttempts,
                    "perAppMode": appFilter.mode.rawValue,
                    "allowedApps": appFilter.selectedBundleIDs.joined(separator: ",")
                ]

                manager.protocolConfiguration = config
                manager.localizedDescription = "FPTN"
                manager.isEnabled = true

                manager.saveToPreferences { error in
                    if let error {
                        logger.error("Save preferences error: \(error.localizedDescription)")
                        continuation.resume(returning: .failure(error))
                        return
                    }

                    logger.info("VPN configuration saved successfully")

                    manager.loadFromPreferences { error in
                        if let error {
                            logger.error("Load preferences error: \(error.localizedDescription)")
                            continuation.resume(returning: .failure(error))
                            return
                        }

                        do {
                            try manager.connection.startVPNTunnel()
                            logger.info("VPN tunnel start requested")
                        } catch {
                            logger.error("startVPNTunnel failed: \(error.localizedDescription)")
                            continuation.resume(returning: .failure(error))
                            return
                        }

                        continuation.resume(returning: .success(manager))
                    }
                }
            }
        }
    }

    // MARK: - Tunnel status observation

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
            connection.isReconnecting = false
            startTimer()
            startRealSpeedMonitoring()
        case .disconnected, .invalid:
            if connection.isConnected || connection.isReconnecting {
                connection.isConnected = false
                stopTimer()
                stopSpeedMonitoring()

                if !userInitiatedDisconnect && SettingsService.shared.reconnectEnabled {
                    scheduleReconnect()
                }
            }
        default:
            break
        }
    }

    // MARK: - Auto-reconnect

    private func scheduleReconnect() {
        let maxAttempts = SettingsService.shared.maxReconnectAttempts
        let delay = SettingsService.shared.reconnectDelay

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                if maxAttempts > 0 && attempt >= maxAttempts {
                    logger.info("Auto-reconnect: reached max \(maxAttempts) attempt(s), giving up")
                    break
                }
                attempt += 1
                logger.info("Auto-reconnect: attempt \(attempt)\(maxAttempts > 0 ? "/\(maxAttempts)" : " (unlimited)")")

                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    self?.connection.isReconnecting = true
                }
                await self?.performConnect()

                // If connect succeeded, tunnel status observer sets isConnected=true; stop looping.
                if await MainActor.run(body: { self?.connection.isConnected ?? false }) {
                    break
                }
            }
            await MainActor.run {
                self?.connection.isReconnecting = false
            }
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

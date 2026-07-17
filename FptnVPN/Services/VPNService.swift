/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine
import Darwin
@preconcurrency import NetworkExtension

private enum TunnelControlAction: String, Codable, Sendable {
    case setLogLevel = "set_log_level"
    case ping
    case getStatus = "get_status"
    case prepareStop = "prepare_stop"
}

private struct TunnelControlMessage: Codable, Sendable {
    let action: TunnelControlAction
    let logLevel: String?
    let initiator: String?

    init(
        action: TunnelControlAction,
        logLevel: String? = nil,
        initiator: String? = nil
    ) {
        self.action = action
        self.logLevel = logLevel
        self.initiator = initiator
    }
}

private struct TunnelControlResponse: Codable, Sendable {
    let ok: Bool
    let message: String
}

private enum StartupAPIRequestRetry {
    static let maxAttempts = 5
    static let timeoutSeconds = 5
    static let delayNanoseconds: UInt64 = 300_000_000
}

@MainActor
final class VPNService: ObservableObject {
    @Published var connection = VPNConnection()

    private var speedTimer: Timer?
    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?
    private var lastExpectedConnectedAt: Date?
    private var conflictDisconnects: Int = 0
    private var remainingFallbackBudget: Int = 0
    private var isUserInitiatedDisconnect: Bool = true
    private var isFallbackReconnecting: Bool = false

    private let tokenService = TokenService.shared
    private let serverSelectionService = ServerSelectionService.shared

    // MARK: - Public

    func syncWithSystem() {
        Task { @MainActor in
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                guard let manager = managers.first else {
                    packetTunnelProvider = nil
                    clearConnectionState(resetErrors: false)
                    return
                }

                packetTunnelProvider = manager
                observeTunnelStatus(manager)
                syncTunnelStatus()
                await refreshTunnelRuntimeSnapshot()
            } catch {
                logger.warning("syncWithSystem: failed to load preferences: \(error.localizedDescription)")
            }
        }
    }

    func connect() {
        Task {
            isUserInitiatedDisconnect = false
            let maxAttempts = SettingsService.shared.maxReconnectAttempts
            remainingFallbackBudget = maxAttempts == 0 ? Int.max : maxAttempts
            await performConnect()
        }
    }

    func disconnect() {
        let manager = packetTunnelProvider
        isUserInitiatedDisconnect = true
        isFallbackReconnecting = false
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = .stopping
        stopTimer()
        stopSpeedMonitoring()

        Task {
            if let session = manager?.connection as? NETunnelProviderSession {
                do {
                    _ = try await Self.sendProviderMessage(
                        TunnelControlMessage(
                            action: .prepareStop,
                            initiator: "app_disconnect"
                        ),
                        via: session,
                        expecting: TunnelControlResponse.self
                    )
                    logger.info("Tunnel acknowledged app disconnect request")
                } catch {
                    logger.warning("Tunnel prepare_stop before disconnect failed: \(error.localizedDescription)")
                }
            }
            manager?.connection.stopVPNTunnel()
        }
    }

    static func pushLogLevelToActiveTunnel(_ level: LogLevel) async {
        let managerResult = await loadActiveManager()
        guard case .success(let manager) = managerResult,
              let session = manager.connection as? NETunnelProviderSession,
              [.connected, .connecting, .reasserting].contains(manager.connection.status) else {
            return
        }

        _ = try? await sendProviderMessage(
            TunnelControlMessage(action: .setLogLevel, logLevel: level.rawValue),
            via: session,
            expecting: TunnelControlResponse.self
        )
    }

    func refreshCachedServerWarning() {
        Task { @MainActor in
            connection.warningMessage = await serverSelectionService.cachedWarningMessage()
        }
    }

    // MARK: - Private connect flow

    private func performConnect() async {
        connection.isConnecting = true
        connection.isReconnecting = false
        connection.isWaitingForNetwork = false
        connection.errorMessage = nil
        connection.runtimeState = .starting
        defer {
            connection.isConnecting = false
            if !connection.isConnected && !connection.isReconnecting {
                connection.runtimeState = nil
            }
        }

        if !NetworkMonitor.shared.isConnected {
            connection.isWaitingForNetwork = true
            logger.info("No network available — waiting for connectivity")
            do {
                try await NetworkMonitor.shared.waitForConnectivity(timeout: 30)
                logger.info("Network ready, proceeding with connection")
            } catch {
                connection.isWaitingForNetwork = false
                connection.errorMessage = "No network connection"
                logger.warning("Network wait timeout — aborting connection")
                return
            }
            connection.isWaitingForNetwork = false
        }

        let server: VPNServer
        var prefetchedAccessToken: String? = nil
        
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
            prefetchedAccessToken = selection.accessToken
        }

        connection.selectedServer = server

        guard let tokenData = await tokenService.getTokenData() else {
            connection.errorMessage = "No token data available"
            logger.error("No token data available")
            return
        }

        let settings = SettingsService.shared
        let sni = settings.sni
        let strategy = settings.censorshipStrategy.rawValue

        let accessToken: String
        if let prefetched = prefetchedAccessToken {
            logger.info("Using pre-fetched access token from server race")
            accessToken = prefetched
        } else {
            let accessTokenResult = await loginToServer(
                server: server,
                username: tokenData.username,
                password: tokenData.password,
                sni: sni,
                censorshipStrategy: strategy
            )
            guard case .success(let token) = accessTokenResult else {
                if case .failure(let error) = accessTokenResult {
                    connection.errorMessage = "Login failed: \(error.localizedDescription)"
                    logger.error("Login error: \(error.localizedDescription)")
                }
                return
            }
            accessToken = token
        }

        let dnsResult = await getDNSInfo(
            server: server,
            accessToken: accessToken,
            sni: sni,
            censorshipStrategy: strategy
        )
        guard case .success(let (dnsIPv4, dnsIPv6)) = dnsResult else {
            if case .failure(let error) = dnsResult {
                connection.errorMessage = "DNS lookup failed: \(error.localizedDescription)"
                logger.error("DNS info error: \(error.localizedDescription)")
            }
            return
        }

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
            packetTunnelProvider = manager
            observeTunnelStatus(manager)
            syncTunnelStatus()
            await refreshTunnelRuntimeSnapshot()
        case .failure(let error):
            connection.errorMessage = "VPN configuration failed: \(error.localizedDescription)"
            logger.error("VPN configuration error: \(error.localizedDescription)")
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

        let apiClient = ApiClientBridge(
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

        var lastErrorMessage = "Unknown error"
        for attempt in 1...StartupAPIRequestRetry.maxAttempts {
            let response = apiClient.post(
                path: "/api/v1/login",
                body: requestBody,
                timeout: StartupAPIRequestRetry.timeoutSeconds
            )
            let responseCode = response.code

            if responseCode == 200 {
                guard let body = response.body,
                      let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String else {
                    lastErrorMessage = "Access token not found"
                    logger.warning("Login response parse failed attempt=\(attempt)/\(StartupAPIRequestRetry.maxAttempts) code=\(responseCode)")
                    await sleepBeforeStartupAPIRetryIfNeeded(attempt)
                    continue
                }

                logger.debug("Login successful, token: \(hideCred(accessToken))")
                return .success(accessToken)
            }

            lastErrorMessage = response.error ?? "Login request failed with code \(responseCode)"
            if responseCode == 401 {
                logger.error("Login rejected by server code=\(responseCode)")
                return .failure(NSError(
                    domain: "VPNService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: lastErrorMessage]
                ))
            }

            logger.warning("Login request attempt \(attempt)/\(StartupAPIRequestRetry.maxAttempts) failed code=\(responseCode)")
            await sleepBeforeStartupAPIRetryIfNeeded(attempt)
        }

        return .failure(NSError(
            domain: "VPNService",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: lastErrorMessage]
        ))
    }

    // MARK: - DNS

    nonisolated private func getDNSInfo(
        server: VPNServer,
        accessToken: String,
        sni: String,
        censorshipStrategy: String
    ) async -> Result<(String, String?), Error> {
        logger.info("DNS request start host=\(server.host) port=\(server.port) sni=\(sni) strategy=\(censorshipStrategy)")
        _ = accessToken

        let apiClient = ApiClientBridge(
            host: server.host,
            port: server.port,
            sni: sni,
            md5Fingerprint: server.md5_fingerprint,
            censorshipStrategy: censorshipStrategy
        )

        var lastErrorMessage = "Unknown error"
        for attempt in 1...StartupAPIRequestRetry.maxAttempts {
            let response = apiClient.get(path: "/api/v1/dns", timeout: StartupAPIRequestRetry.timeoutSeconds)
            let responseCode = response.code

            if responseCode == 200 {
                guard let body = response.body,
                      let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dnsIPv4 = json["dns"] as? String else {
                    lastErrorMessage = "DNS info not found"
                    logger.warning("DNS response parse failed attempt=\(attempt)/\(StartupAPIRequestRetry.maxAttempts) code=\(responseCode)")
                    await sleepBeforeStartupAPIRetryIfNeeded(attempt)
                    continue
                }

                let dnsIPv6 = Self.validIPv6(json["dns_ipv6"] as? String)
                logger.debug("DNS response parsed ipv6_available=\(dnsIPv6 != nil)")
                return .success((dnsIPv4, dnsIPv6))
            }

            lastErrorMessage = response.error ?? "DNS request failed with code \(responseCode)"
            logger.warning("DNS request attempt \(attempt)/\(StartupAPIRequestRetry.maxAttempts) failed code=\(responseCode)")
            await sleepBeforeStartupAPIRetryIfNeeded(attempt)
        }

        return .failure(NSError(
            domain: "VPNService",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: lastErrorMessage]
        ))
    }

    nonisolated private func sleepBeforeStartupAPIRetryIfNeeded(_ attempt: Int) async {
        guard attempt < StartupAPIRequestRetry.maxAttempts else { return }
        try? await Task.sleep(nanoseconds: StartupAPIRequestRetry.delayNanoseconds)
    }

    // MARK: - VPN tunnel configuration

    private func configureAndStartVPN(
        server: VPNServer,
        accessToken: String,
        dnsIPv4: String,
        dnsIPv6: String?,
        sni: String,
        bypassMethod: String
    ) async -> Result<NETunnelProviderManager, Error> {
        let isAutoMode: Bool
        if case .auto = connection.connectionMode {
            isAutoMode = true
        } else {
            isAutoMode = false
        }
        let maxAttempts: Int
        if isAutoMode {
            // In auto mode, let the tunnel retry the same server 3 times before failing back to the app for all-server racing
            maxAttempts = 3
        } else {
            // In manual mode, respect the user's settings
            maxAttempts = SettingsService.shared.maxReconnectAttempts
        }
        
        let reconnectPolicy = TunnelReconnectPolicy(
            isEnabled: SettingsService.shared.reconnectEnabled,
            maxAttempts: maxAttempts,
            delaySeconds: SettingsService.shared.reconnectDelay
        )

        return await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { existing, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }

                let manager = existing?.first ?? NETunnelProviderManager()

                let config = NETunnelProviderProtocol()
                config.serverAddress = "FptnVPN"
                config.providerBundleIdentifier = "net.mrmidi.FptnVPN.FptnVPNTunnel"

                let appFilter = AppFilterService.shared
                var providerConfiguration: [String: Any] = [
                    "server": server.host,
                    "port": server.port,
                    "accessToken": accessToken,
                    "dnsIPv4": dnsIPv4,
                    "sni": sni,
                    "logLevel": SettingsService.shared.logLevel.rawValue,
                    "md5Fingerprint": server.md5_fingerprint,
                    "bypassMethod": bypassMethod,
                    "websocketIdleTimeoutSeconds": SettingsService.shared.websocketIdleTimeoutSeconds,
                    "reconnectEnabled": reconnectPolicy.isEnabled,
                    "maxReconnectAttempts": reconnectPolicy.maxAttempts,
                    "reconnectDelaySeconds": reconnectPolicy.delaySeconds,
                    "perAppMode": appFilter.mode.rawValue,
                    "allowedApps": appFilter.selectedBundleIDs.joined(separator: ",")
                ]
                if let dnsIPv6 {
                    providerConfiguration["dnsIPv6"] = dnsIPv6
                }
                if SettingsService.shared.customDnsEnabled && !SettingsService.shared.customDnsIPv4.isEmpty {
                    providerConfiguration["customDnsIPv4"] = SettingsService.shared.customDnsIPv4
                }
                config.providerConfiguration = providerConfiguration

                // Force APNs (push) traffic through the tunnel. excludeAPNs is only
                // honored when includeAllNetworks is true, which also makes the tunnel
                // fail-closed (all traffic captured) while connected.
                if #available(iOS 16.4, *), SettingsService.shared.routePushThroughTunnel {
                    config.includeAllNetworks = true
                    config.excludeAPNs = false
                }

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

                        switch manager.connection.status {
                        case .connected, .connecting, .reasserting:
                            logger.info("VPN tunnel already active with status=\(manager.connection.status.rawValue)")
                        default:
                            do {
                                try manager.connection.startVPNTunnel()
                                logger.info("VPN tunnel start requested")
                            } catch {
                                logger.error("startVPNTunnel failed: \(error.localizedDescription)")
                                continuation.resume(returning: .failure(error))
                                return
                            }
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
                await self?.refreshTunnelRuntimeSnapshot()
            }
        }
    }

    private func syncTunnelStatus() {
        guard let tunnelConnection = packetTunnelProvider?.connection else {
            clearConnectionState(resetErrors: false)
            return
        }

        let status = tunnelConnection.status
        logger.info("Tunnel status changed: \(status.diagnosticName) (\(status.rawValue))")

        switch status {
        case .connected:
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = false
            connection.vpnConflictDetected = false
            lastExpectedConnectedAt = Date()
            conflictDisconnects = 0
            startTimer()
            startRealSpeedMonitoring()
            
            // Reset budget on successful connection
            let maxAttempts = SettingsService.shared.maxReconnectAttempts
            remainingFallbackBudget = maxAttempts == 0 ? Int.max : maxAttempts
        case .reasserting:
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = true
            connection.runtimeState = .reasserting
            connection.downloadSpeed = 0
            connection.uploadSpeed = 0
            startTimer()
            stopSpeedMonitoring()
        case .connecting:
            connection.isConnected = false
            connection.isConnecting = true
            connection.isReconnecting = false
            connection.runtimeState = .starting
            stopSpeedMonitoring()
        case .disconnecting:
            connection.isConnected = false
            connection.isConnecting = false
            connection.isReconnecting = false
            connection.runtimeState = .stopping
            stopSpeedMonitoring()
        case .disconnected, .invalid:
            if status == .disconnected {
                logLastDisconnectError(from: tunnelConnection)
                detectConflictAfterDisconnect()
                
                // If it's an unexpected disconnect (connection drop) and fallback reconnect is enabled
                if !isUserInitiatedDisconnect && SettingsService.shared.reconnectEnabled {
                    triggerFallbackReconnect()
                }
            }
            clearConnectionState(resetErrors: false)
        @unknown default:
            break
        }
    }

    /// Detects potential VPN conflicts by monitoring rapid disconnects
    /// after a connection attempt (another VPN may have stolen priority).
    private func detectConflictAfterDisconnect() {
        guard let connectedAt = lastExpectedConnectedAt else { return }
        let connectedDuration = Date().timeIntervalSince(connectedAt)

        // If we connected but dropped within 3 seconds, likely a conflict
        if connectedDuration < 3.0 && conflictDisconnects >= 2 {
            logger.warning("VPN conflict detected — rapid disconnects after connection (\(conflictDisconnects) times)")
            connection.vpnConflictDetected = true
            conflictDisconnects = 0
            return
        }

        // Track rapid disconnect-reconnect cycles
        if connectedDuration < 5.0 {
            conflictDisconnects += 1
        } else {
            conflictDisconnects = 0
        }
        lastExpectedConnectedAt = nil
    }

    private func refreshTunnelRuntimeSnapshot() async {
        guard let manager = packetTunnelProvider,
              let session = manager.connection as? NETunnelProviderSession,
              [.connected, .connecting, .reasserting].contains(manager.connection.status) else {
            return
        }

        let snapshot: TunnelRuntimeSnapshot
        do {
            snapshot = try await Self.sendProviderMessage(
                TunnelControlMessage(action: .getStatus),
                via: session,
                expecting: TunnelRuntimeSnapshot.self
            )
        } catch {
            logger.warning("Tunnel get_status failed: \(error.localizedDescription)")
            return
        }

        connection.runtimeState = snapshot.runtimeState
        connection.lastTransportError = snapshot.lastTransportError
        connection.lastStopReason = snapshot.lastStopReason

        if snapshot.isReasserting {
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = true
        }

        logger.info(
            "Tunnel snapshot state=\(snapshot.runtimeState.rawValue) reasserting=\(snapshot.isReasserting) reconnect_attempt=\(snapshot.reconnectAttempt)/\(snapshot.maxReconnectAttempts == 0 ? "∞" : String(snapshot.maxReconnectAttempts)) ipv6=\(snapshot.ipv6Enabled) ws_started=\(snapshot.websocketStarted) ws_idle=\(snapshot.websocketIdleTimeoutSeconds)s last_error=\(snapshot.lastTransportError ?? snapshot.websocketLastError ?? "-") last_stop=\(snapshot.lastStopReason ?? "-") last_inbound=\(snapshot.lastInboundActivityAt ?? "-") last_outbound=\(snapshot.lastOutboundActivityAt ?? "-")"
        )

        // NE fires .connected when setTunnelNetworkSettings is applied, one frame before
        // finishStart(nil) — so the first snapshot often comes back with ws_started=false.
        // Retry once after a short delay so the UI reflects the real connected state.
        if !snapshot.websocketStarted,
           manager.connection.status == .connected {
            try? await Task.sleep(for: .seconds(2))
            await refreshTunnelRuntimeSnapshot()
        }
    }

    private func clearConnectionState(resetErrors: Bool) {
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = nil
        connection.lastTransportError = nil
        connection.lastStopReason = nil
        if resetErrors {
            connection.errorMessage = nil
        }
        stopTimer()
        stopSpeedMonitoring()
    }

    private func logLastDisconnectError(from connection: NEVPNConnection) {
        connection.fetchLastDisconnectError { error in
            guard let error else {
                logger.info("Tunnel last disconnect error: none")
                return
            }

            let nsError = error as NSError
            let reason = Self.describeDisconnectError(nsError)
            logger.warning(
                "Tunnel last disconnect error domain=\(nsError.domain) code=\(nsError.code) reason=\(reason) description=\(nsError.localizedDescription)"
            )
            if reason == "plugin_failed" {
                let report = TunnelDiagnosticsStore.shared.makeProviderFailureReport(disconnectReason: reason)
                logger.warning("\(report.summaryLine)")
            }
        }
    }

    private func triggerFallbackReconnect() {
        guard !isUserInitiatedDisconnect else { return }
        guard !isFallbackReconnecting else { return }
        
        isFallbackReconnecting = true
        
        Task { @MainActor in
            defer { isFallbackReconnecting = false }
            
            let delaySeconds = SettingsService.shared.reconnectDelay
            logger.info("Scheduling fallback reconnect after \(delaySeconds)s")
            try? await Task.sleep(for: .seconds(delaySeconds))
            
            guard !isUserInitiatedDisconnect else { return }
            
            let maxAttempts = SettingsService.shared.maxReconnectAttempts
            if maxAttempts != 0 {
                remainingFallbackBudget -= 1
                if remainingFallbackBudget <= 0 {
                    logger.warning("Reconnection budget exhausted. Stopping reconnection attempts.")
                    connection.errorMessage = "All servers unreachable (attempts exhausted)"
                    return
                }
            }
            
            logger.info("Triggering fallback reconnect attempt. Remaining budget: \(maxAttempts == 0 ? "infinite" : String(remainingFallbackBudget))")
            
            connection.isReconnecting = true
            connection.runtimeState = .starting
            
            await performConnect()
        }
    }

    // MARK: - Timers

    private func startRealSpeedMonitoring() {
        guard speedTimer == nil else { return }

        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connection.isConnected, !self.connection.isReconnecting else { return }
                self.connection.downloadSpeed = Double.random(in: 5...15)
                self.connection.uploadSpeed = Double.random(in: 2...8)
                self.appendSpeedSample()
            }
        }
    }

    private func appendSpeedSample() {
        let sample = SpeedSample(
            timestamp: Date(),
            downloadMbps: connection.downloadSpeed / 1_000_000,
            uploadMbps: connection.uploadSpeed / 1_000_000
        )
        connection.speedHistory.append(sample)
        if connection.speedHistory.count > 300 {
            connection.speedHistory.removeFirst(connection.speedHistory.count - 300)
        }
    }

    private func startTimer() {
        // Anchor to the system's connection timestamp so the displayed duration
        // reflects real elapsed time across backgrounding and app relaunches,
        // not just foreground ticks. Set once and preserved across
        // reasserting/reconnect so the total session time isn't reset on blips.
        guard connection.connectedAt == nil else { return }
        connection.connectedAt = packetTunnelProvider?.connection.connectedDate ?? Date()
    }

    private func stopTimer() {
        connection.connectedAt = nil
    }

    private func stopSpeedMonitoring() {
        speedTimer?.invalidate()
        speedTimer = nil
        connection.downloadSpeed = 0
        connection.uploadSpeed = 0
    }

    // MARK: - Formatting

    func formatConnectionTime() -> String {
        guard let connectedAt = connection.connectedAt else { return "00:00:00" }
        let total = Int(max(0, Date().timeIntervalSince(connectedAt)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func formatSpeed(_ speed: Double) -> String {
        if speed < 1000 {
            return String(format: "%.1f Kbps", speed)
        } else {
            return String(format: "%.1f Mbps", speed / 1000)
        }
    }

    // MARK: - Provider messaging

    private static func loadActiveManager() async -> Result<NETunnelProviderManager, Error> {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }

                guard let manager = managers?.first else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "VPNService",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "No active tunnel manager"]
                    )))
                    return
                }

                continuation.resume(returning: .success(manager))
            }
        }
    }

    nonisolated private static func sendProviderMessage<Response: Decodable & Sendable>(
        _ message: TunnelControlMessage,
        via session: NETunnelProviderSession,
        expecting responseType: Response.Type
    ) async throws -> Response {
        guard let payload = try? JSONEncoder().encode(message) else {
            throw NSError(
                domain: "VPNService",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode provider message"]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { responseData in
                    guard let responseData else {
                        continuation.resume(throwing: NSError(
                            domain: "VPNService",
                            code: -12,
                            userInfo: [NSLocalizedDescriptionKey: "Tunnel did not return a response"]
                        ))
                        return
                    }

                    do {
                        let decoded = try JSONDecoder().decode(responseType, from: responseData)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private extension NEVPNStatus {
    var diagnosticName: String {
        switch self {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }
}

private extension VPNService {
    nonisolated static func validIPv6(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) == 1 ? value : nil }
    }

    nonisolated static func describeDisconnectError(_ error: NSError) -> String {
        guard error.domain == NEVPNConnectionErrorDomain else {
            return "provider_or_system_error"
        }

        switch error.code {
        case NEVPNConnectionError.overslept.rawValue:
            return "overslept"
        case NEVPNConnectionError.noNetworkAvailable.rawValue:
            return "no_network_available"
        case NEVPNConnectionError.unrecoverableNetworkChange.rawValue:
            return "unrecoverable_network_change"
        case NEVPNConnectionError.configurationFailed.rawValue:
            return "configuration_failed"
        case NEVPNConnectionError.serverAddressResolutionFailed.rawValue:
            return "server_address_resolution_failed"
        case NEVPNConnectionError.serverNotResponding.rawValue:
            return "server_not_responding"
        case NEVPNConnectionError.serverDead.rawValue:
            return "server_dead"
        case NEVPNConnectionError.authenticationFailed.rawValue:
            return "authentication_failed"
        case NEVPNConnectionError.clientCertificateInvalid.rawValue:
            return "client_certificate_invalid"
        case NEVPNConnectionError.clientCertificateNotYetValid.rawValue:
            return "client_certificate_not_yet_valid"
        case NEVPNConnectionError.clientCertificateExpired.rawValue:
            return "client_certificate_expired"
        case NEVPNConnectionError.pluginFailed.rawValue:
            return "plugin_failed"
        case NEVPNConnectionError.configurationNotFound.rawValue:
            return "configuration_not_found"
        case NEVPNConnectionError.pluginDisabled.rawValue:
            return "plugin_disabled"
        case NEVPNConnectionError.negotiationFailed.rawValue:
            return "negotiation_failed"
        case NEVPNConnectionError.serverDisconnected.rawValue:
            return "server_disconnected"
        case NEVPNConnectionError.serverCertificateInvalid.rawValue:
            return "server_certificate_invalid"
        case NEVPNConnectionError.serverCertificateNotYetValid.rawValue:
            return "server_certificate_not_yet_valid"
        case NEVPNConnectionError.serverCertificateExpired.rawValue:
            return "server_certificate_expired"
        default:
            return "unknown_nevpn_error"
        }
    }
}

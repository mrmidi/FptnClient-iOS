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

@MainActor
final class VPNService: ObservableObject {
    @Published var connection = VPNConnection()

    private var timer: Timer?
    private var speedTimer: Timer?
    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?

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
            await performConnect()
        }
    }

    func disconnect() {
        let manager = packetTunnelProvider
        packetTunnelProvider = nil

        if let observer = tunnelStatusObserver {
            NotificationCenter.default.removeObserver(observer)
            tunnelStatusObserver = nil
        }

        clearConnectionState(resetErrors: true)

        Task {
            if let session = manager?.connection as? NETunnelProviderSession {
                _ = try? await Self.sendProviderMessage(
                    TunnelControlMessage(
                        action: .prepareStop,
                        initiator: "app_disconnect"
                    ),
                    via: session,
                    expecting: TunnelControlResponse.self
                )
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
        connection.errorMessage = nil
        connection.runtimeState = .starting
        defer {
            connection.isConnecting = false
            if !connection.isConnected && !connection.isReconnecting {
                connection.runtimeState = nil
            }
        }

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
        let strategy = settings.censorshipStrategy.rawValue

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

        let response = apiClient.post(path: "/api/v1/login", body: requestBody, timeout: 10)
        let responseCode = response.code

        guard responseCode == 200 else {
            let errorMessage = response.error ?? "Unknown error"
            logger.error("Login request failed host=\(server.host) port=\(server.port) sni=\(sni) code=\(responseCode) error=\(errorMessage)")
            return .failure(NSError(
                domain: "VPNService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }

        guard let body = response.body,
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

        let response = apiClient.get(path: "/api/v1/dns", timeout: 10)
        let responseCode = response.code

        guard responseCode == 200 else {
            let errorMessage = response.error ?? "Unknown error"
            logger.error("DNS request failed host=\(server.host) port=\(server.port) sni=\(sni) code=\(responseCode) error=\(errorMessage)")
            return .failure(NSError(
                domain: "VPNService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }

        guard let body = response.body,
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

        let dnsIPv6 = Self.validIPv6(json["dns_ipv6"] as? String)
        logger.debug("DNS IPv4: \(dnsIPv4)  IPv6: \(dnsIPv6 ?? "none")")
        return .success((dnsIPv4, dnsIPv6))
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
        let reconnectPolicy = TunnelReconnectPolicy(
            isEnabled: SettingsService.shared.reconnectEnabled,
            maxAttempts: SettingsService.shared.maxReconnectAttempts,
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
                config.providerConfiguration = providerConfiguration

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
            startTimer()
            startRealSpeedMonitoring()
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
            clearConnectionState(resetErrors: false)
            if status == .disconnected {
                logLastDisconnectError(from: tunnelConnection)
            }
        @unknown default:
            break
        }
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
            logger.warning(
                "Tunnel last disconnect error domain=\(nsError.domain) code=\(nsError.code) reason=\(Self.describeDisconnectError(nsError)) description=\(nsError.localizedDescription)"
            )
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
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }

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

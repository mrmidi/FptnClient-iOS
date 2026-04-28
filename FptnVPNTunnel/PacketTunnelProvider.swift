/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Darwin
import Network
import NetworkExtension

private enum TunnelControlAction: String, Codable {
    case setLogLevel = "set_log_level"
    case ping
    case getStatus = "get_status"
    case prepareStop = "prepare_stop"
}

private struct TunnelControlMessage: Codable {
    let action: TunnelControlAction
    let logLevel: String?
    let initiator: String?
}

private struct TunnelControlResponse: Codable {
    let ok: Bool
    let message: String
}

private enum TunnelRuntimeState: String, Codable {
    case idle
    case starting
    case connected
    case reasserting
    case waitingForNetwork
    case stopping
    case failed
}

private enum ReconnectScheduleOutcome {
    case scheduled
    case waitingForNetwork
    case unavailable
}

private enum LocalStopInitiator: String, Codable {
    case appDisconnect = "app_disconnect"
    case providerFailure = "provider_failure"
    case systemStop = "system_stop"
}

private struct TunnelRuntimeSnapshot: Codable {
    let runtimeState: TunnelRuntimeState
    let isReasserting: Bool
    let reconnectAttempt: Int
    let maxReconnectAttempts: Int
    let lastTransportError: String?
    let lastStopReason: String?
    let lastStopReasonRawValue: Int?
    let localStopInitiator: String?
    let lastInboundActivityAt: String?
    let lastOutboundActivityAt: String?
    let packetFlowReadPackets: Int64
    let packetFlowReadBytes: Int64
    let transportReceivedPackets: Int64
    let transportReceivedBytes: Int64
    let packetFlowWritePackets: Int64
    let packetFlowWriteBytes: Int64
    let websocketSendFailures: Int64
    let dnsIPv4: String?
    let dnsIPv6: String?
    let tunnelIPv4: String?
    let tunnelIPv6: String?
    let ipv6Enabled: Bool
    let websocketRunning: Bool
    let websocketStarted: Bool
    let websocketIdleTimeoutSeconds: Int
    let websocketLastError: String?
    let websocketLastDisconnectReason: String?
}

private struct TunnelConfiguration {
    let serverIP: String
    let serverPort: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String?
    let sni: String
    let md5Fingerprint: String
    let logLevel: String
    let websocketStrategy: String
    let websocketIdleTimeoutSeconds: Int
    let reconnectEnabled: Bool
    let maxReconnectAttempts: Int
    let reconnectDelaySeconds: Int
    let tunIPv4: String
    let tunIPv4Gateway: String
    let tunIPv6: String

    init?(providerConfiguration: [String: Any]) {
        guard
            let serverIP = providerConfiguration["server"] as? String,
            let serverPort = providerConfiguration["port"] as? Int,
            let accessToken = providerConfiguration["accessToken"] as? String,
            let dnsIPv4 = providerConfiguration["dnsIPv4"] as? String,
            let sni = providerConfiguration["sni"] as? String,
            let md5Fingerprint = providerConfiguration["md5Fingerprint"] as? String
        else {
            return nil
        }

        let dnsIPv6 = Self.validIPv6(providerConfiguration["dnsIPv6"] as? String)
        let logLevel = providerConfiguration["logLevel"] as? String ?? "info"
        let bypassMethod = providerConfiguration["bypassMethod"] as? String ?? "SNI"
        let websocketIdleTimeoutSeconds = providerConfiguration["websocketIdleTimeoutSeconds"] as? Int ?? 60
        let reconnectEnabled = providerConfiguration["reconnectEnabled"] as? Bool ?? true
        let maxReconnectAttempts = providerConfiguration["maxReconnectAttempts"] as? Int ?? 5
        let reconnectDelaySeconds = providerConfiguration["reconnectDelaySeconds"] as? Int ?? 2

        self.serverIP = serverIP
        self.serverPort = serverPort
        self.accessToken = accessToken
        self.dnsIPv4 = dnsIPv4
        self.dnsIPv6 = dnsIPv6
        self.sni = sni
        self.md5Fingerprint = md5Fingerprint
        self.logLevel = logLevel
        self.websocketIdleTimeoutSeconds = websocketIdleTimeoutSeconds
        self.reconnectEnabled = reconnectEnabled
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.tunIPv4 = "10.8.0.2"
        self.tunIPv4Gateway = "10.8.0.1"
        self.tunIPv6 = "fd00::1"
        self.websocketStrategy = "\(bypassMethod);idle_timeout=\(websocketIdleTimeoutSeconds);tun_ipv6=\(self.tunIPv6)"
    }

    private static func validIPv6(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) == 1 ? value : nil }
    }
}

private struct PacketCounters {
    var packetFlowReadPackets: Int64 = 0
    var packetFlowReadBytes: Int64 = 0
    var transportReceivedPackets: Int64 = 0
    var transportReceivedBytes: Int64 = 0
    var packetFlowWritePackets: Int64 = 0
    var packetFlowWriteBytes: Int64 = 0
    var websocketSendFailures: Int64 = 0
    var pendingWebsocketSendFailures: Int64 = 0
    var lastInboundActivityAt: Date?
    var lastOutboundActivityAt: Date?
    var lastSendFailureWarningAt: Date?
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let eventQueue = DispatchQueue(label: "net.mrmidi.FptnVPN.tunnel.events")
    private let stateLock = NSLock()

    private var wsClient: WebsocketClientBridge?
    private var configuration: TunnelConfiguration?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var telemetryTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var runtimeState: TunnelRuntimeState = .idle
    private var localStopInitiator: LocalStopInitiator?
    private var shutdownRequested = false
    private var isNetworkPathSatisfied = true
    private var websocketGeneration = 0
    private var didApplyNetworkSettings = false
    private var didStartReadLoop = false
    private var isReadLoopActive = false
    private var reconnectAttempt = 0
    private var lastTransportError: String?
    private var lastStopReason: String?
    private var lastStopReasonRawValue: Int?
    private var counters = PacketCounters()

    private let runtimeReconnectDelayCapSeconds = 60
    private let activityResumeLogThresholdSeconds = 60
    private let sendFailureWarningIntervalSeconds: TimeInterval = 1
    private let sendFailureWarningPacketThreshold: Int64 = 100

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        bootstrapLogging()
        logger.info("PacketTunnelProvider startTunnel")
        _ = options

        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = config.providerConfiguration,
              let runtimeConfig = TunnelConfiguration(providerConfiguration: providerConfig) else {
            let err = makeError("Missing or incomplete providerConfiguration")
            logger.error("startTunnel failed: \(err.localizedDescription)")
            completionHandler(err)
            return
        }

        setTunnelLogLevel(rawValue: runtimeConfig.logLevel)
        logger.info("Tunnel started (level=\(runtimeConfig.logLevel))")
        logger.info(
            "Tunnel websocket settings idle_timeout=\(runtimeConfig.websocketIdleTimeoutSeconds)s reconnect_enabled=\(runtimeConfig.reconnectEnabled) max_attempts=\(runtimeConfig.maxReconnectAttempts == 0 ? "infinite" : String(runtimeConfig.maxReconnectAttempts)) delay=\(runtimeConfig.reconnectDelaySeconds)s"
        )

        stateLock.lock()
        configuration = runtimeConfig
        startCompletion = completionHandler
        runtimeState = .starting
        localStopInitiator = nil
        shutdownRequested = false
        isNetworkPathSatisfied = true
        websocketGeneration = 0
        didApplyNetworkSettings = false
        didStartReadLoop = false
        isReadLoopActive = false
        reconnectAttempt = 0
        lastTransportError = nil
        lastStopReason = nil
        lastStopReasonRawValue = nil
        counters = PacketCounters()
        stateLock.unlock()

        updateRuntimeState(.starting, reason: "startTunnel")
        startPathMonitor()
        scheduleStartTimeout(seconds: 15)
        startWebSocket(using: runtimeConfig, context: "initial_start")
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let description = describeStopReason(reason.rawValue)
        let initiator = currentOrDefaultStopInitiator()

        stateLock.lock()
        shutdownRequested = true
        lastStopReasonRawValue = Int(reason.rawValue)
        lastStopReason = description
        isReadLoopActive = false
        stateLock.unlock()

        updateRuntimeState(.stopping, reason: "stopTunnel(\(description))")
        logger.warning(
            "PacketTunnelProvider stopTunnel reason=\(reason.rawValue) (\(description)) initiator=\(initiator.rawValue)"
        )

        cancelStartTimeout()
        cancelPendingReconnect()
        stopPathMonitor()
        stopTelemetry()
        finishStart(with: makeError("Tunnel stopped before startup completed"))
        replaceWebSocketClient(with: nil, stopCurrent: true)

        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        logger.debug("handleAppMessage \(messageData.count) bytes")

        guard let message = try? JSONDecoder().decode(TunnelControlMessage.self, from: messageData) else {
            completionHandler?(encodeResponse(TunnelControlResponse(ok: false, message: "invalid_payload")))
            return
        }

        switch message.action {
        case .setLogLevel:
            setTunnelLogLevel(rawValue: message.logLevel)
            logger.info("Tunnel log level updated via IPC: \(message.logLevel ?? "info")")
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "log_level_updated")))
        case .ping:
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "pong")))
        case .prepareStop:
            if let initiator = message.initiator, initiator == LocalStopInitiator.appDisconnect.rawValue {
                stateLock.lock()
                localStopInitiator = .appDisconnect
                shutdownRequested = true
                isReadLoopActive = false
                stateLock.unlock()
                cancelPendingReconnect()
                logger.info("Marked local stop initiator via IPC: \(initiator); reconnect will be suppressed")
            }
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "stop_initiator_recorded")))
        case .getStatus:
            completionHandler?(try? JSONEncoder().encode(currentSnapshot()))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let snapshot = currentSnapshot()
        logger.info(
            "PacketTunnelProvider sleep state=\(snapshot.runtimeState.rawValue) reconnect_attempt=\(snapshot.reconnectAttempt) last_error=\(snapshot.lastTransportError ?? "-") \(activityDiagnosticsDescription(for: snapshot))"
        )
        completionHandler()
    }

    override func wake() {
        let snapshot = currentSnapshot()
        logger.info(
            "PacketTunnelProvider wake state=\(snapshot.runtimeState.rawValue) reconnect_attempt=\(snapshot.reconnectAttempt) last_error=\(snapshot.lastTransportError ?? "-") \(activityDiagnosticsDescription(for: snapshot))"
        )

        if snapshot.runtimeState == .connected && !snapshot.websocketStarted {
            logger.warning("Tunnel wake detected connected state without a running websocket — connection likely lost during sleep")
            eventQueue.async { [weak self] in
                guard let self else { return }
                let generation = self.currentWebSocketGeneration()
                self.handleTransportDisconnected(
                    generation: generation,
                    wasConnected: true,
                    reason: "connection lost during sleep"
                )
            }
        }
    }

    // MARK: - WebSocket lifecycle

    private func startWebSocket(using configuration: TunnelConfiguration, context: String) {
        let generation: Int
        stateLock.lock()
        if shutdownRequested {
            stateLock.unlock()
            logger.info("Skipping WebSocket start context=\(context) because shutdown was requested")
            return
        }
        websocketGeneration += 1
        generation = websocketGeneration
        stateLock.unlock()

        let client = WebsocketClientBridge(
            serverIP: configuration.serverIP,
            serverPort: configuration.serverPort,
            tunInterfaceIPv4: configuration.tunIPv4,
            sni: configuration.sni,
            accessToken: configuration.accessToken,
            md5Fingerprint: configuration.md5Fingerprint,
            censorshipStrategy: configuration.websocketStrategy,
            packetCallback: { [weak self] packet in
                self?.handleIncomingPacketFromServer(packet, generation: generation)
            },
            connectedCallback: { [weak self] in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    self?.handleTransportConnected(generation: generation)
                }
            },
            disconnectedCallback: { [weak self] wasConnected, reason in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    self?.handleTransportDisconnected(
                        generation: generation,
                        wasConnected: wasConnected,
                        reason: reason
                    )
                }
            }
        )

        replaceWebSocketClient(with: client, stopCurrent: false)
        guard client.start() else {
            replaceWebSocketClient(with: nil, stopCurrent: false)
            logger.error("WebSocket start failed context=\(context) generation=\(generation)")
            eventQueue.async { [weak self] in
                self?.handleTransportDisconnected(
                    generation: generation,
                    wasConnected: false,
                    reason: "WebSocket start failed"
                )
            }
            return
        }

        logger.debug("WebSocket start issued context=\(context) generation=\(generation)")
    }

    private func handleTransportConnected(generation: Int) {
        let configuration: TunnelConfiguration?
        let shouldApplySettings: Bool

        stateLock.lock()
        let isStaleCallback = generation != websocketGeneration
        let shouldIgnoreForShutdown = shutdownRequested
        configuration = self.configuration
        shouldApplySettings = !didApplyNetworkSettings && runtimeState == .starting
        stateLock.unlock()

        if isStaleCallback {
            logger.info("Ignoring stale websocket connected callback generation=\(generation)")
            return
        }
        if shouldIgnoreForShutdown {
            logger.info("Ignoring websocket connected callback generation=\(generation) because shutdown was requested")
            replaceWebSocketClient(with: nil, stopCurrent: true)
            return
        }

        guard let configuration else {
            logger.error("Transport connected without runtime configuration")
            return
        }

        logger.info("Tunnel transport connected \(activityDiagnosticsDescription())")

        if shouldApplySettings {
            logger.info("Tunnel websocket connected — applying network settings")
            applyNetworkSettings(configuration: configuration) { [weak self] error in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    guard let self else { return }
                    if let error {
                        logger.error("setTunnelNetworkSettings error: \(error.localizedDescription)")
                        self.updateRuntimeState(.failed, reason: "setTunnelNetworkSettings error")
                        self.finishStart(with: error)
                        self.replaceWebSocketClient(with: nil, stopCurrent: true)
                        return
                    }

                    self.stateLock.lock()
                    self.didApplyNetworkSettings = true
                    let shouldStartReadLoop = !self.didStartReadLoop
                    self.didStartReadLoop = true
                    self.isReadLoopActive = true
                    self.reconnectAttempt = 0
                    self.lastTransportError = nil
                    self.stateLock.unlock()

                    self.updateRuntimeState(.connected, reason: "initial websocket connected")
                    if shouldStartReadLoop {
                        self.startReadLoop()
                    }
                    self.startTelemetryIfNeeded()
                    self.finishStart(with: nil)
                }
            }
            return
        }

        stateLock.lock()
        reconnectAttempt = 0
        lastTransportError = nil
        stateLock.unlock()

        updateRuntimeState(.connected, reason: "transport recovered")
    }

    private func handleTransportDisconnected(
        generation: Int,
        wasConnected: Bool,
        reason: String
    ) {
        var stopInitiator: LocalStopInitiator?
        var isStaleCallback = false
        var shouldSuppressForShutdown = false

        stateLock.lock()
        stopInitiator = localStopInitiator
        isStaleCallback = generation != websocketGeneration
        shouldSuppressForShutdown = shutdownRequested
        stateLock.unlock()

        if isStaleCallback {
            logger.info("Ignoring stale websocket disconnected callback generation=\(generation) reason=\(reason)")
            return
        }

        logger.warning(
            "Tunnel websocket disconnected generation=\(generation) was_connected=\(wasConnected) reason=\(reason) stop_initiator=\(stopInitiator?.rawValue ?? "-") \(activityDiagnosticsDescription())"
        )
        replaceWebSocketClient(with: nil, stopCurrent: false)
        cancelStartTimeout()

        let configuration: TunnelConfiguration?
        let currentState: TunnelRuntimeState

        stateLock.lock()
        configuration = self.configuration
        currentState = runtimeState
        lastTransportError = reason
        stateLock.unlock()

        guard currentState != .stopping else {
            logger.info("Ignoring transport disconnect because tunnel is already stopping")
            return
        }

        if shouldSuppressForShutdown || stopInitiator == .appDisconnect || stopInitiator == .systemStop {
            logger.info(
                "Suppressing reconnect after transport disconnect because stop was already requested by \(stopInitiator?.rawValue ?? "shutdown")"
            )
            updateRuntimeState(.stopping, reason: "transport disconnected after local stop request")
            return
        }

        if currentState == .starting || configuration == nil {
            updateRuntimeState(.failed, reason: "initial transport failure")
            finishStart(with: makeError(reason))
            return
        }

        switch scheduleReconnectIfPossible() {
        case .scheduled:
            updateRuntimeState(.reasserting, reason: "transport loss")
        case .waitingForNetwork:
            updateRuntimeState(.waitingForNetwork, reason: "transport loss without network path")
        case .unavailable:
            failRuntimeTunnel(reason: reason)
        }
    }

    private func scheduleReconnectIfPossible() -> ReconnectScheduleOutcome {
        var workItem: DispatchWorkItem?
        var nextAttempt = 0
        var delaySeconds = 0
        var maxAttempts = 0
        var exceededConfiguredBudget = false
        var generation = 0
        var shouldWaitForNetwork = false

        stateLock.lock()
        guard let currentConfiguration = configuration else {
            stateLock.unlock()
            logger.info("Skipping reconnect schedule because runtime configuration is missing")
            return .unavailable
        }

        guard !shutdownRequested else {
            stateLock.unlock()
            logger.info("Skipping reconnect schedule because shutdown was requested")
            return .unavailable
        }

        nextAttempt = reconnectAttempt + 1
        delaySeconds = computedReconnectDelaySeconds(
            attempt: nextAttempt,
            baseDelaySeconds: currentConfiguration.reconnectDelaySeconds
        )
        maxAttempts = currentConfiguration.maxReconnectAttempts

        guard currentConfiguration.reconnectEnabled else {
            stateLock.unlock()
            logger.info("Skipping reconnect schedule because reconnect is disabled")
            return .unavailable
        }

        exceededConfiguredBudget = maxAttempts != 0 && nextAttempt > maxAttempts
        reconnectAttempt = nextAttempt
        generation = websocketGeneration
        shouldWaitForNetwork = !isNetworkPathSatisfied

        if shouldWaitForNetwork {
            stateLock.unlock()
            logger.warning(
                "Waiting for network path before reconnect attempt \(nextAttempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") \(activityDiagnosticsDescription())"
            )
            return .waitingForNetwork
        }

        reconnectWorkItem?.cancel()

        workItem = DispatchWorkItem { [weak self] in
            self?.performReconnectAttempt(expectedGeneration: generation)
        }
        reconnectWorkItem = workItem
        stateLock.unlock()

        if exceededConfiguredBudget {
            logger.warning(
                "Reconnect attempt \(nextAttempt) exceeded configured budget \(maxAttempts); continuing runtime recovery with backoff \(delaySeconds)s \(activityDiagnosticsDescription())"
            )
        } else {
            logger.warning(
                "Scheduling reconnect attempt \(nextAttempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") after \(delaySeconds)s \(activityDiagnosticsDescription())"
            )
        }

        if let workItem {
            eventQueue.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        }

        return .scheduled
    }

    private func performReconnectAttempt(expectedGeneration: Int) {
        let configuration: TunnelConfiguration?
        let currentState: TunnelRuntimeState
        let attempt: Int
        let maxAttempts: Int
        let shouldSkip: Bool
        let pathSatisfied: Bool

        stateLock.lock()
        configuration = self.configuration
        currentState = runtimeState
        attempt = reconnectAttempt
        maxAttempts = configuration?.maxReconnectAttempts ?? 0
        shouldSkip = shutdownRequested || expectedGeneration != websocketGeneration
        pathSatisfied = isNetworkPathSatisfied
        reconnectWorkItem = nil
        stateLock.unlock()

        if shouldSkip {
            logger.info("Skipping reconnect attempt \(attempt) because it is stale or shutdown was requested")
            return
        }

        guard currentState == .reasserting, let configuration else {
            return
        }

        guard pathSatisfied else {
            logger.warning("Reconnect attempt \(attempt) delayed because network path is unsatisfied")
            updateRuntimeState(.waitingForNetwork, reason: "network path unsatisfied before reconnect")
            return
        }

        logger.warning(
            "Starting reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") \(activityDiagnosticsDescription())"
        )
        startWebSocket(using: configuration, context: "reconnect_attempt_\(attempt)")
    }

    private func computedReconnectDelaySeconds(
        attempt: Int,
        baseDelaySeconds: Int
    ) -> Int {
        let safeBaseDelay = max(1, baseDelaySeconds)
        let backoffStep = min(max(0, attempt - 1), 5)
        let multiplier = 1 << backoffStep
        return min(runtimeReconnectDelayCapSeconds, safeBaseDelay * multiplier)
    }

    private func failRuntimeTunnel(reason: String) {
        stateLock.lock()
        localStopInitiator = .providerFailure
        stateLock.unlock()

        updateRuntimeState(.failed, reason: "runtime reconnect exhausted")
        logger.error("Tunnel runtime failure: \(reason)")
        cancelPendingReconnect()
        cancelTunnelWithError(makeError(reason))
    }

    // MARK: - Network settings

    private func applyNetworkSettings(
        configuration: TunnelConfiguration,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.tunIPv4Gateway)

        let ipv4 = NEIPv4Settings(
            addresses: [configuration.tunIPv4],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dnsServers = [configuration.dnsIPv4] + (configuration.dnsIPv6.map { [$0] } ?? [])
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        let ipv6Enabled = configuration.dnsIPv6 != nil
        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(
                addresses: [configuration.tunIPv6],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }
        settings.mtu = 1500

        let ipv4IncludedRoutes = ipv4.includedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let ipv4ExcludedRoutes = ipv4.excludedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let ipv6IncludedRoutes = settings.ipv6Settings?.includedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let ipv6ExcludedRoutes = settings.ipv6Settings?.excludedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let matchDomains = dns.matchDomains?.joined(separator: ",") ?? "-"
        logger.info(
            "Applying tunnel settings ipv4=\(configuration.tunIPv4)/255.255.255.0 ipv4_included_routes=\(ipv4IncludedRoutes) ipv4_excluded_routes=\(ipv4ExcludedRoutes) ipv6=\(ipv6Enabled ? "\(configuration.tunIPv6)/64" : "none") ipv6_included_routes=\(ipv6IncludedRoutes) ipv6_excluded_routes=\(ipv6ExcludedRoutes) dns=\(dnsServers.joined(separator: ",")) match_domains=\(matchDomains) mtu=1500"
        )

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    // MARK: - Packet flow

    private func startReadLoop() {
        guard shouldContinueReadLoop() else { return }

        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.shouldContinueReadLoop() else { return }

            var totalBytes: Int64 = 0
            var sendFailures: Int64 = 0
            let client = self.currentWebSocketClient()

            for packet in packets {
                totalBytes += Int64(packet.count)
                if client?.sendPacket(packet) != true {
                    sendFailures += 1
                }
            }

            self.recordPacketFlowRead(
                packetCount: Int64(packets.count),
                byteCount: totalBytes,
                sendFailures: sendFailures
            )
            self.startReadLoop()
        }
    }

    private func handleIncomingPacketFromServer(_ packet: Data, generation: Int) {
        guard generation == currentWebSocketGeneration() else { return }
        guard shouldHandlePackets() else { return }

        let protocolNumber = ipProtocolNumber(for: packet)
        packetFlow.writePackets([packet], withProtocols: [protocolNumber])
        recordPacketFlowWrite(byteCount: Int64(packet.count))
    }

    private func shouldContinueReadLoop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isReadLoopActive
    }

    private func shouldHandlePackets() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didApplyNetworkSettings && runtimeState != .stopping && runtimeState != .failed
    }

    private func currentWebSocketClient() -> WebsocketClientBridge? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wsClient
    }

    private func currentWebSocketGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return websocketGeneration
    }

    private func replaceWebSocketClient(
        with newClient: WebsocketClientBridge?,
        stopCurrent: Bool
    ) {
        var previousClient: WebsocketClientBridge?
        stateLock.lock()
        previousClient = wsClient
        wsClient = newClient
        stateLock.unlock()

        if stopCurrent {
            _ = previousClient?.stop()
        }
    }

    private func recordPacketFlowRead(
        packetCount: Int64,
        byteCount: Int64,
        sendFailures: Int64
    ) {
        guard packetCount > 0 || sendFailures > 0 else { return }

        let now = Date()
        var previousOutboundActivityAt: Date?
        var shouldLogSendFailures = false
        var pendingSendFailures: Int64 = 0
        var totalSendFailures: Int64 = 0
        var suppressSendFailureLog = false

        stateLock.lock()
        previousOutboundActivityAt = counters.lastOutboundActivityAt
        counters.packetFlowReadPackets += packetCount
        counters.packetFlowReadBytes += byteCount
        counters.websocketSendFailures += sendFailures
        totalSendFailures = counters.websocketSendFailures
        if packetCount > 0 {
            counters.lastOutboundActivityAt = now
        }
        if sendFailures > 0 {
            suppressSendFailureLog = runtimeState == .stopping ||
                runtimeState == .failed ||
                wsClient == nil ||
                !isReadLoopActive
            if !suppressSendFailureLog {
                counters.pendingWebsocketSendFailures += sendFailures
                let elapsed = counters.lastSendFailureWarningAt.map { now.timeIntervalSince($0) } ?? .infinity
                shouldLogSendFailures = counters.pendingWebsocketSendFailures >= sendFailureWarningPacketThreshold ||
                    elapsed >= sendFailureWarningIntervalSeconds
                if shouldLogSendFailures {
                    pendingSendFailures = counters.pendingWebsocketSendFailures
                    counters.pendingWebsocketSendFailures = 0
                    counters.lastSendFailureWarningAt = now
                }
            }
        }
        stateLock.unlock()

        if packetCount > 0 {
            logActivityResumedIfNeeded(
                direction: "outbound",
                previousActivityAt: previousOutboundActivityAt,
                now: now,
                packetCount: packetCount,
                byteCount: byteCount
            )
        }

        if shouldLogSendFailures {
            logger.warning(
                "Tunnel transport send failures throttled pending=\(pendingSendFailures) total=\(totalSendFailures) latest_batch_failures=\(sendFailures) outbound_packets=\(packetCount) outbound_bytes=\(byteCount) \(activityDiagnosticsDescription())"
            )
        }
    }

    private func recordPacketFlowWrite(byteCount: Int64) {
        let now = Date()
        var previousInboundActivityAt: Date?

        stateLock.lock()
        previousInboundActivityAt = counters.lastInboundActivityAt
        counters.transportReceivedPackets += 1
        counters.transportReceivedBytes += byteCount
        counters.packetFlowWritePackets += 1
        counters.packetFlowWriteBytes += byteCount
        counters.lastInboundActivityAt = now
        stateLock.unlock()

        logActivityResumedIfNeeded(
            direction: "inbound",
            previousActivityAt: previousInboundActivityAt,
            now: now,
            packetCount: 1,
            byteCount: byteCount
        )
    }

    private func ipProtocolNumber(for packet: Data) -> NSNumber {
        guard let first = packet.first else {
            return NSNumber(value: AF_INET)
        }
        return NSNumber(value: Int32(Int(first >> 4) == 6 ? AF_INET6 : AF_INET))
    }

    // MARK: - Timers

    private func scheduleStartTimeout(seconds: Int) {
        cancelStartTimeout()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            logger.error("Tunnel initial start timed out after \(seconds)s")
            self.updateRuntimeState(.failed, reason: "initial start timeout")
            self.finishStart(with: self.makeError("WebSocket connection timeout"))
            self.replaceWebSocketClient(with: nil, stopCurrent: true)
        }

        stateLock.lock()
        startTimeoutWorkItem = workItem
        stateLock.unlock()

        eventQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: workItem)
    }

    private func cancelStartTimeout() {
        stateLock.lock()
        let workItem = startTimeoutWorkItem
        startTimeoutWorkItem = nil
        stateLock.unlock()
        workItem?.cancel()
    }

    private func cancelPendingReconnect() {
        stateLock.lock()
        let workItem = reconnectWorkItem
        reconnectWorkItem = nil
        stateLock.unlock()
        workItem?.cancel()
    }

    private func startPathMonitor() {
        stopPathMonitor()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.eventQueue.async { [weak self] in
                self?.handleNetworkPathChanged(isSatisfied: path.status == .satisfied)
            }
        }

        stateLock.lock()
        pathMonitor = monitor
        stateLock.unlock()

        monitor.start(queue: eventQueue)
    }

    private func stopPathMonitor() {
        stateLock.lock()
        let monitor = pathMonitor
        pathMonitor = nil
        stateLock.unlock()
        monitor?.cancel()
    }

    private func handleNetworkPathChanged(isSatisfied: Bool) {
        var shouldScheduleReconnect = false
        var attempt = 0
        var maxAttempts = 0

        stateLock.lock()
        let previous = isNetworkPathSatisfied
        isNetworkPathSatisfied = isSatisfied
        if isSatisfied && runtimeState == .waitingForNetwork && !shutdownRequested {
            shouldScheduleReconnect = true
            attempt = reconnectAttempt
            maxAttempts = configuration?.maxReconnectAttempts ?? 0
        }
        stateLock.unlock()

        guard previous != isSatisfied || shouldScheduleReconnect else { return }

        logger.info("Network path satisfied=\(isSatisfied)")
        if shouldScheduleReconnect {
            scheduleReconnectAttempt(attempt: max(1, attempt), maxAttempts: maxAttempts)
        }
    }

    private func scheduleReconnectAttempt(attempt: Int, maxAttempts: Int) {
        var workItem: DispatchWorkItem?
        var delaySeconds = 0
        var generation = 0
        var exceededConfiguredBudget = false

        stateLock.lock()
        guard let configuration, !shutdownRequested, isNetworkPathSatisfied else {
            stateLock.unlock()
            logger.info("Skipping reconnect attempt \(attempt) after path change because state is no longer reconnectable")
            return
        }

        reconnectAttempt = attempt
        generation = websocketGeneration
        delaySeconds = computedReconnectDelaySeconds(
            attempt: attempt,
            baseDelaySeconds: configuration.reconnectDelaySeconds
        )
        exceededConfiguredBudget = maxAttempts != 0 && attempt > maxAttempts
        reconnectWorkItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in
            self?.performReconnectAttempt(expectedGeneration: generation)
        }
        reconnectWorkItem = workItem
        stateLock.unlock()

        if exceededConfiguredBudget {
            logger.warning(
                "Reconnect attempt \(attempt) exceeded configured budget \(maxAttempts); continuing runtime recovery with backoff \(delaySeconds)s after network path recovery \(activityDiagnosticsDescription())"
            )
        } else {
            logger.warning(
                "Scheduling reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") after \(delaySeconds)s after network path recovery \(activityDiagnosticsDescription())"
            )
        }

        if let workItem {
            eventQueue.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        }
        updateRuntimeState(.reasserting, reason: "network path recovered")
    }

    private func startTelemetryIfNeeded() {
        stateLock.lock()
        if telemetryTimer != nil {
            stateLock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in
            self?.emitTelemetry()
        }
        telemetryTimer = timer
        stateLock.unlock()

        timer.resume()
    }

    private func stopTelemetry() {
        stateLock.lock()
        let timer = telemetryTimer
        telemetryTimer = nil
        stateLock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func emitTelemetry() {
        let snapshot = currentSnapshot()
        logger.info(
            "Tunnel telemetry state=\(snapshot.runtimeState.rawValue) reasserting=\(snapshot.isReasserting) reconnect_attempt=\(snapshot.reconnectAttempt)/\(snapshot.maxReconnectAttempts == 0 ? "∞" : String(snapshot.maxReconnectAttempts)) packetflow_read_packets=\(snapshot.packetFlowReadPackets) packetflow_read_bytes=\(snapshot.packetFlowReadBytes) packetflow_write_packets=\(snapshot.packetFlowWritePackets) packetflow_write_bytes=\(snapshot.packetFlowWriteBytes) transport_received_packets=\(snapshot.transportReceivedPackets) transport_received_bytes=\(snapshot.transportReceivedBytes) send_failures=\(snapshot.websocketSendFailures) last_inbound=\(snapshot.lastInboundActivityAt ?? "-") last_outbound=\(snapshot.lastOutboundActivityAt ?? "-") \(activityDiagnosticsDescription(for: snapshot))"
        )

        let clientAttached = currentWebSocketClient() != nil
        let readLoopActive = shouldContinueReadLoop()
        if snapshot.runtimeState == .connected && !clientAttached {
            logger.warning("Tunnel telemetry detected connected state without an attached websocket client")
        }
        if snapshot.runtimeState == .connected && !readLoopActive {
            logger.warning("Tunnel telemetry detected connected state with an inactive packet read loop")
        }
    }

    // MARK: - State helpers

    private func updateRuntimeState(_ state: TunnelRuntimeState, reason: String) {
        var previousState: TunnelRuntimeState = .idle
        var previousReasserting = false
        let newReasserting = state == .reasserting || state == .waitingForNetwork

        stateLock.lock()
        previousState = runtimeState
        previousReasserting = reasserting
        runtimeState = state
        stateLock.unlock()

        reasserting = newReasserting
        if previousState != state {
            logger.info("Tunnel state \(previousState.rawValue) -> \(state.rawValue) reason=\(reason)")
        }
        if previousReasserting != newReasserting {
            logger.info("Tunnel reasserting=\(newReasserting)")
        }
    }

    private func finishStart(with error: Error?) {
        var completion: ((Error?) -> Void)?

        stateLock.lock()
        completion = startCompletion
        startCompletion = nil
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        stateLock.unlock()

        completion?(error)
    }

    private func currentSnapshot() -> TunnelRuntimeSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }

        let status = wsClient?.status
        return TunnelRuntimeSnapshot(
            runtimeState: runtimeState,
            isReasserting: runtimeState == .reasserting || runtimeState == .waitingForNetwork,
            reconnectAttempt: reconnectAttempt,
            maxReconnectAttempts: configuration?.maxReconnectAttempts ?? 0,
            lastTransportError: lastTransportError,
            lastStopReason: lastStopReason,
            lastStopReasonRawValue: lastStopReasonRawValue,
            localStopInitiator: localStopInitiator?.rawValue,
            lastInboundActivityAt: iso8601(counters.lastInboundActivityAt),
            lastOutboundActivityAt: iso8601(counters.lastOutboundActivityAt),
            packetFlowReadPackets: counters.packetFlowReadPackets,
            packetFlowReadBytes: counters.packetFlowReadBytes,
            transportReceivedPackets: counters.transportReceivedPackets,
            transportReceivedBytes: counters.transportReceivedBytes,
            packetFlowWritePackets: counters.packetFlowWritePackets,
            packetFlowWriteBytes: counters.packetFlowWriteBytes,
            websocketSendFailures: counters.websocketSendFailures,
            dnsIPv4: configuration?.dnsIPv4,
            dnsIPv6: configuration?.dnsIPv6,
            tunnelIPv4: configuration?.tunIPv4,
            tunnelIPv6: configuration?.tunIPv6,
            ipv6Enabled: configuration?.dnsIPv6 != nil,
            websocketRunning: status?.running ?? false,
            websocketStarted: status?.started ?? false,
            websocketIdleTimeoutSeconds: status?.idleTimeoutSeconds ?? configuration?.websocketIdleTimeoutSeconds ?? 0,
            websocketLastError: status?.lastError,
            websocketLastDisconnectReason: status?.lastDisconnectReason
        )
    }

    private func currentOrDefaultStopInitiator() -> LocalStopInitiator {
        stateLock.lock()
        let initiator = localStopInitiator ?? .systemStop
        localStopInitiator = initiator
        stateLock.unlock()
        return initiator
    }

    private func describeStopReason(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: return "none"
        case 1: return "userInitiated"
        case 2: return "providerFailed"
        case 3: return "noNetworkAvailable"
        case 4: return "unrecoverableNetworkChange"
        case 5: return "providerDisabled"
        case 6: return "authenticationCanceled"
        case 7: return "configurationFailed"
        case 8: return "idleTimeout"
        case 9: return "configurationDisabled"
        case 10: return "configurationRemoved"
        case 11: return "superseded"
        case 12: return "userLogout"
        case 13: return "userSwitch"
        case 14: return "connectionFailed"
        case 15: return "sleep"
        case 16: return "appUpdate"
        case 17: return "internalError"
        default: return "unknown(\(rawValue))"
        }
    }

    private func encodeResponse(_ response: TunnelControlResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "org.fptn.tunnel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func iso8601(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    private func activityDiagnosticsDescription() -> String {
        activityDiagnosticsDescription(for: currentSnapshot())
    }

    private func activityDiagnosticsDescription(for snapshot: TunnelRuntimeSnapshot) -> String {
        let inboundIdle = idleDurationDescription(from: snapshot.lastInboundActivityAt)
        let outboundIdle = idleDurationDescription(from: snapshot.lastOutboundActivityAt)
        let clientAttached = currentWebSocketClient() != nil
        let readLoopActive = shouldContinueReadLoop()
        return "inbound_idle=\(inboundIdle) outbound_idle=\(outboundIdle) client_attached=\(clientAttached) read_loop_active=\(readLoopActive)"
    }

    private func idleDurationDescription(from iso8601DateString: String?) -> String {
        guard let iso8601DateString,
              let date = ISO8601DateFormatter().date(from: iso8601DateString) else {
            return "never"
        }
        return "\(Int(max(0, Date().timeIntervalSince(date))))s"
    }

    private func logActivityResumedIfNeeded(
        direction: String,
        previousActivityAt: Date?,
        now: Date,
        packetCount: Int64,
        byteCount: Int64
    ) {
        guard let previousActivityAt else { return }

        let idleSeconds = Int(now.timeIntervalSince(previousActivityAt))
        guard idleSeconds >= activityResumeLogThresholdSeconds else { return }

        logger.info(
            "Tunnel \(direction) activity resumed after \(idleSeconds)s idle packets=\(packetCount) bytes=\(byteCount)"
        )
    }
}

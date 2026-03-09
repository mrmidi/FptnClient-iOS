/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
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
    case stopping
    case failed
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
}

private struct TunnelConfiguration {
    let serverIP: String
    let serverPort: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String
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

        let dnsIPv6 = providerConfiguration["dnsIPv6"] as? String ?? "fd00::1"
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
        self.websocketStrategy = "\(bypassMethod);idle_timeout=\(websocketIdleTimeoutSeconds)"
        self.tunIPv4 = "10.8.0.2"
        self.tunIPv4Gateway = "10.8.0.1"
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
    var lastInboundActivityAt: Date?
    var lastOutboundActivityAt: Date?
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
    private var runtimeState: TunnelRuntimeState = .idle
    private var localStopInitiator: LocalStopInitiator?
    private var didApplyNetworkSettings = false
    private var didStartReadLoop = false
    private var isReadLoopActive = false
    private var reconnectAttempt = 0
    private var lastTransportError: String?
    private var lastStopReason: String?
    private var lastStopReasonRawValue: Int?
    private var counters = PacketCounters()

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
                stateLock.unlock()
                logger.info("Marked local stop initiator via IPC: \(initiator)")
            }
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "stop_initiator_recorded")))
        case .getStatus:
            completionHandler?(try? JSONEncoder().encode(currentSnapshot()))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        logger.info("PacketTunnelProvider sleep state=\(currentSnapshot().runtimeState.rawValue)")
        completionHandler()
    }

    override func wake() {
        logger.info("PacketTunnelProvider wake state=\(currentSnapshot().runtimeState.rawValue)")
    }

    // MARK: - WebSocket lifecycle

    private func startWebSocket(using configuration: TunnelConfiguration, context: String) {
        let client = WebsocketClientBridge(
            serverIP: configuration.serverIP,
            serverPort: configuration.serverPort,
            tunInterfaceIPv4: configuration.tunIPv4,
            sni: configuration.sni,
            accessToken: configuration.accessToken,
            md5Fingerprint: configuration.md5Fingerprint,
            censorshipStrategy: configuration.websocketStrategy,
            packetCallback: { [weak self] packet in
                self?.handleIncomingPacketFromServer(packet)
            },
            connectedCallback: { [weak self] in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    self?.handleTransportConnected()
                }
            },
            disconnectedCallback: { [weak self] wasConnected, reason in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    self?.handleTransportDisconnected(
                        wasConnected: wasConnected,
                        reason: reason
                    )
                }
            }
        )

        replaceWebSocketClient(with: client, stopCurrent: false)
        guard client.start() else {
            replaceWebSocketClient(with: nil, stopCurrent: false)
            logger.error("WebSocket start failed context=\(context)")
            eventQueue.async { [weak self] in
                self?.handleTransportDisconnected(
                    wasConnected: false,
                    reason: "WebSocket start failed"
                )
            }
            return
        }

        logger.debug("WebSocket start issued context=\(context)")
    }

    private func handleTransportConnected() {
        let configuration: TunnelConfiguration?
        let shouldApplySettings: Bool

        stateLock.lock()
        configuration = self.configuration
        shouldApplySettings = !didApplyNetworkSettings && runtimeState == .starting
        stateLock.unlock()

        guard let configuration else {
            logger.error("Transport connected without runtime configuration")
            return
        }

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
        wasConnected: Bool,
        reason: String
    ) {
        logger.warning("Tunnel websocket disconnected was_connected=\(wasConnected) reason=\(reason)")
        replaceWebSocketClient(with: nil, stopCurrent: false)
        cancelStartTimeout()

        let configuration: TunnelConfiguration?
        let currentState: TunnelRuntimeState

        stateLock.lock()
        configuration = self.configuration
        currentState = runtimeState
        lastTransportError = reason
        stateLock.unlock()

        guard currentState != .stopping else { return }

        if currentState == .starting || configuration == nil {
            updateRuntimeState(.failed, reason: "initial transport failure")
            finishStart(with: makeError(reason))
            return
        }

        if scheduleReconnectIfPossible() {
            updateRuntimeState(.reasserting, reason: "transport loss")
            return
        }

        failRuntimeTunnel(reason: reason)
    }

    private func scheduleReconnectIfPossible() -> Bool {
        var workItem: DispatchWorkItem?
        var nextAttempt = 0
        var delaySeconds = 0
        var maxAttempts = 0

        stateLock.lock()
        defer { stateLock.unlock() }

        guard let configuration else {
            return false
        }

        nextAttempt = reconnectAttempt + 1
        delaySeconds = configuration.reconnectDelaySeconds
        maxAttempts = configuration.maxReconnectAttempts

        guard configuration.reconnectEnabled,
              configuration.maxReconnectAttempts == 0 || nextAttempt <= configuration.maxReconnectAttempts else {
            return false
        }

        reconnectAttempt = nextAttempt
        reconnectWorkItem?.cancel()

        workItem = DispatchWorkItem { [weak self] in
            self?.performReconnectAttempt()
        }
        reconnectWorkItem = workItem

        logger.warning(
            "Scheduling reconnect attempt \(nextAttempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") after \(delaySeconds)s"
        )

        if let workItem {
            eventQueue.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        }

        return true
    }

    private func performReconnectAttempt() {
        let configuration: TunnelConfiguration?
        let currentState: TunnelRuntimeState
        let attempt: Int
        let maxAttempts: Int

        stateLock.lock()
        configuration = self.configuration
        currentState = runtimeState
        attempt = reconnectAttempt
        maxAttempts = configuration?.maxReconnectAttempts ?? 0
        reconnectWorkItem = nil
        stateLock.unlock()

        guard currentState == .reasserting, let configuration else {
            return
        }

        logger.warning(
            "Starting reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)")"
        )
        startWebSocket(using: configuration, context: "reconnect_attempt_\(attempt)")
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

        let dnsServers = [configuration.dnsIPv4, configuration.dnsIPv6]
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500

        let ipv4IncludedRoutes = ipv4.includedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let ipv4ExcludedRoutes = ipv4.excludedRoutes?.map(\.destinationAddress).joined(separator: ",") ?? "-"
        let matchDomains = dns.matchDomains?.joined(separator: ",") ?? "-"
        logger.info(
            "Applying tunnel settings ipv4=\(configuration.tunIPv4)/255.255.255.0 ipv4_included_routes=\(ipv4IncludedRoutes) ipv4_excluded_routes=\(ipv4ExcludedRoutes) ipv6=none ipv6_included_routes=- ipv6_excluded_routes=- dns=\(dnsServers.joined(separator: ",")) match_domains=\(matchDomains) mtu=1500"
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

    private func handleIncomingPacketFromServer(_ packet: Data) {
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

        stateLock.lock()
        counters.packetFlowReadPackets += packetCount
        counters.packetFlowReadBytes += byteCount
        counters.websocketSendFailures += sendFailures
        if packetCount > 0 {
            counters.lastOutboundActivityAt = Date()
        }
        stateLock.unlock()
    }

    private func recordPacketFlowWrite(byteCount: Int64) {
        stateLock.lock()
        counters.transportReceivedPackets += 1
        counters.transportReceivedBytes += byteCount
        counters.packetFlowWritePackets += 1
        counters.packetFlowWriteBytes += byteCount
        counters.lastInboundActivityAt = Date()
        stateLock.unlock()
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
            "Tunnel telemetry state=\(snapshot.runtimeState.rawValue) reasserting=\(snapshot.isReasserting) reconnect_attempt=\(snapshot.reconnectAttempt)/\(snapshot.maxReconnectAttempts == 0 ? "∞" : String(snapshot.maxReconnectAttempts)) packetflow_read_packets=\(snapshot.packetFlowReadPackets) packetflow_read_bytes=\(snapshot.packetFlowReadBytes) packetflow_write_packets=\(snapshot.packetFlowWritePackets) packetflow_write_bytes=\(snapshot.packetFlowWriteBytes) transport_received_packets=\(snapshot.transportReceivedPackets) transport_received_bytes=\(snapshot.transportReceivedBytes) send_failures=\(snapshot.websocketSendFailures) last_inbound=\(snapshot.lastInboundActivityAt ?? "-") last_outbound=\(snapshot.lastOutboundActivityAt ?? "-")"
        )
    }

    // MARK: - State helpers

    private func updateRuntimeState(_ state: TunnelRuntimeState, reason: String) {
        var previousState: TunnelRuntimeState = .idle

        stateLock.lock()
        previousState = runtimeState
        runtimeState = state
        stateLock.unlock()

        reasserting = state == .reasserting
        if previousState != state {
            logger.info("Tunnel state \(previousState.rawValue) -> \(state.rawValue) reason=\(reason)")
        }
        logger.info("Tunnel reasserting=\(reasserting)")
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

        return TunnelRuntimeSnapshot(
            runtimeState: runtimeState,
            isReasserting: runtimeState == .reasserting,
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
            websocketSendFailures: counters.websocketSendFailures
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
}

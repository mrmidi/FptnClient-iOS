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
    let memoryResidentBytes: UInt64?
    let memoryPhysFootprintBytes: UInt64?
    let nativeReceivedPackets: Int64
    let nativeReceivedBytes: Int64
    let nativeCallbackEnterCount: Int64
    let nativeCallbackExitCount: Int64
    let nativeCallbackByteCount: Int64
    let nativeInPacketCallback: Bool
    // PR2: all PR1A–1C native diagnostics for app-side visibility.
    let nativeRequestedRcvbufBytes: Int
    let nativeRequestedSndbufBytes: Int
    let nativeEffectiveRcvbufBytes: Int
    let nativeEffectiveSndbufBytes: Int
    let nativeSocketBufferSetErrorCount: Int
    let nativeLiveClients: Int
    let nativeActiveReaderCoroutines: Int
    let nativeActiveSenderCoroutines: Int
    let nativeQueuedPackets: UInt64
    let nativeQueuedBytes: UInt64
    let nativeQueuedBytesPeak: UInt64
    let nativeQueueFullCount: UInt64
    let nativeDisconnectCode: UInt16
    let nativeStopOrigin: UInt16
    let nativeActiveOperations: UInt32
    let nativeStopCleanupCompleted: Bool
}

private struct TunnelConfiguration {
    let serverIP: String
    let serverPort: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String?
    let customDnsIPv4: String?
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
        let customDns = providerConfiguration["customDnsIPv4"] as? String
        let customDnsIPv4 = (customDns?.isEmpty == false) ? customDns : nil

        self.serverIP = serverIP
        self.serverPort = serverPort
        self.accessToken = accessToken
        self.dnsIPv4 = dnsIPv4
        self.dnsIPv6 = dnsIPv6
        self.customDnsIPv4 = customDnsIPv4
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

// PR2: explicit invariant violations, logged once per type.
enum ProviderInvariant: Hashable {
    case multipleNativeClients
    case incompleteNativeTeardown
}

// PR2: process-lifetime read ownership token. Prevents cross-session
// generation collisions (generation resets to 0 on each startTunnel).
private struct PacketReadToken: Equatable {
    let session: UInt64
    let generation: Int
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let eventQueue = DispatchQueue(label: "net.mrmidi.FptnVPN.tunnel.events")
    private let stateLock = NSLock()

    private var wsClient: WebsocketClientBridge?
    private var configuration: TunnelConfiguration?
    private var assignedIPv4: String?
    private var assignedIPv6: String?
    private var appliedIPv4: String?
    private var appliedIPv6: String?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var telemetryTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var runtimeState: TunnelRuntimeState = .idle
    private var localStopInitiator: LocalStopInitiator?
    private var shutdownRequested = false
    private var isNetworkPathSatisfied = true
    private var lastNetworkPathChangeAt: Date?
    private var lastNetworkPathSatisfied: Bool?
    private var lastNetworkPathSummary = "unknown"
    private var websocketGeneration = 0
    private var didApplyNetworkSettings = false
    private var isReadLoopActive = false
    private var isPacketReadPending = false
    private var reconnectAttempt = 0
    private var lastTransportError: String?
    private var lastStopReason: String?
    private var lastStopReasonRawValue: Int?
    private var counters = PacketCounters()
    private var lastMemoryWarningAt: Date?
    private var readBackpressureUntil: Date?
    private var readBackpressureWorkItem: DispatchWorkItem?
    private var consecutiveSendFailureBatches = 0

    // PR2: invariant tracking (logged once per type).
    private var loggedInvariantViolations: Set<ProviderInvariant> = []
    // PR2: process-lifetime session token + generation-based read ownership.
    private var tunnelSession: UInt64 = 0
    private var pendingReadToken: PacketReadToken?
    // PR2: final native status preserved before detaching a client.
    private var lastNativeStatus: WebsocketClientStatus?
    private var lastNativeStatusGeneration: Int?

    private let runtimeReconnectDelayCapSeconds = 60
    private let activityResumeLogThresholdSeconds = 60
    private let sendFailureWarningIntervalSeconds: TimeInterval = 1
    private let sendFailureWarningPacketThreshold: Int64 = 100
    private let sendFailureBackpressureBaseDelaySeconds: TimeInterval = 0.25
    private let sendFailureBackpressureMaxDelaySeconds: TimeInterval = 2
    private let pathChangeBackpressureDelaySeconds: TimeInterval = 1
    private let memoryWarningLogIntervalSeconds: TimeInterval = 60
    private let pathHandoffHintWindowSeconds: TimeInterval = 10

    deinit {
        recordProviderEvent(category: "lifecycle", message: "PacketTunnelProvider deinit")
        updateDiagnosticsHeartbeat(lastEvent: "deinit")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        bootstrapLogging()
        TunnelCrashSignalInstaller.installIfPossible()
        logger.info("PacketTunnelProvider startTunnel")
        recordProviderEvent(category: "lifecycle", message: "startTunnel")
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
        // PR2: increment session token. Generation resets but session
        // is process-lifetime unique, preventing cross-session collisions.
        tunnelSession &+= 1
        websocketGeneration = 0
        didApplyNetworkSettings = false
        isReadLoopActive = false
        // PR2: do NOT reset isPacketReadPending here. An outstanding
        // readPackets callback from the old session still exists.
        // Only the owning callback may clear it via token check.
        reconnectAttempt = 0
        lastTransportError = nil
        lastStopReason = nil
        lastStopReasonRawValue = nil
        lastNetworkPathChangeAt = nil
        lastNetworkPathSatisfied = nil
        lastNetworkPathSummary = "unknown"
        counters = PacketCounters()
        lastMemoryWarningAt = nil
        readBackpressureUntil = nil
        readBackpressureWorkItem = nil
        consecutiveSendFailureBatches = 0
        assignedIPv4 = nil
        assignedIPv6 = nil
        appliedIPv4 = nil
        appliedIPv6 = nil
        // PR2: reset per-session state.
        loggedInvariantViolations.removeAll()
        lastNativeStatus = nil
        lastNativeStatusGeneration = nil
        stateLock.unlock()

        updateRuntimeState(.starting, reason: "startTunnel")
        updateDiagnosticsHeartbeat(lastEvent: "startTunnel")
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
        // PR2: do NOT clear isPacketReadPending — the outstanding
        // readPackets callback still exists and owns the slot.
        stateLock.unlock()

        updateRuntimeState(.stopping, reason: "stopTunnel(\(description))")
        logger.warning(
            "PacketTunnelProvider stopTunnel reason=\(reason.rawValue) (\(description)) initiator=\(initiator.rawValue)"
        )
        recordProviderEvent(
            category: "lifecycle",
            message: "stopTunnel reason=\(reason.rawValue) (\(description)) initiator=\(initiator.rawValue)",
            runtimeState: "stopping"
        )
        updateDiagnosticsHeartbeat(lastEvent: "stopTunnel")

        cancelStartTimeout()
        cancelPendingReconnect()
        cancelReadBackpressure()
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
                cancelReadBackpressure()
                logger.info("Marked local stop initiator via IPC: \(initiator); reconnect will be suppressed")
                recordProviderEvent(category: "ipc", message: "prepare_stop initiator=\(initiator)")
                updateDiagnosticsHeartbeat(lastEvent: "prepare_stop")
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
        recordProviderEvent(
            category: "lifecycle",
            message: "sleep state=\(snapshot.runtimeState.rawValue)",
            runtimeState: snapshot.runtimeState.rawValue,
            reconnectAttempt: snapshot.reconnectAttempt
        )
        updateDiagnosticsHeartbeat(snapshot: snapshot, lastEvent: "sleep")
        completionHandler()
    }

    override func wake() {
        let snapshot = currentSnapshot()
        logger.info(
            "PacketTunnelProvider wake state=\(snapshot.runtimeState.rawValue) reconnect_attempt=\(snapshot.reconnectAttempt) last_error=\(snapshot.lastTransportError ?? "-") \(activityDiagnosticsDescription(for: snapshot))"
        )
        recordProviderEvent(
            category: "lifecycle",
            message: "wake state=\(snapshot.runtimeState.rawValue)",
            runtimeState: snapshot.runtimeState.rawValue,
            reconnectAttempt: snapshot.reconnectAttempt
        )
        updateDiagnosticsHeartbeat(snapshot: snapshot, lastEvent: "wake")

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
            recordProviderEvent(category: "websocket", message: "skip_start context=\(context) shutdown=true")
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
                self.recordProviderEvent(category: "websocket_callback", message: "connected_callback_enter generation=\(generation)", generation: generation)
                self.eventQueue.async { [weak self] in
                    self?.handleTransportConnected(generation: generation)
                }
            },
            disconnectedCallback: { [weak self] wasConnected, reason in
                guard let self else { return }
                self.recordProviderEvent(category: "websocket_callback", message: "disconnected_callback_enter generation=\(generation) was_connected=\(wasConnected) reason=\(reason)", generation: generation)
                self.eventQueue.async { [weak self] in
                    self?.handleTransportDisconnected(
                        generation: generation,
                        wasConnected: wasConnected,
                        reason: reason
                    )
                }
            },
            ipAssignedCallback: { [weak self] ipv4, ipv6 in
                guard let self else { return }
                self.stateLock.lock()
                self.assignedIPv4 = ipv4
                self.assignedIPv6 = ipv6
                self.stateLock.unlock()
                logger.info("IP assignment received from bridge")
            }
        )

        // PR2: pass expectedGeneration so a stale replacement is
        // rejected before detaching the current bridge. If rejected,
        // do NOT call client.start() — the bridge was stopped.
        guard replaceWebSocketClient(
            with: client,
            stopCurrent: true,
            stopOrigin: .swiftReconnect,
            expectedGeneration: generation
        ) else {
            logger.info("WebSocket replacement rejected (shutdown/stale) context=\(context) generation=\(generation)")
            return
        }
        guard client.start() else {
            replaceWebSocketClient(with: nil, stopCurrent: false, expectedGeneration: generation)
            logger.error("WebSocket start failed context=\(context) generation=\(generation)")
            recordProviderEvent(category: "websocket", message: "start_failed context=\(context) generation=\(generation)", generation: generation)
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
        recordProviderEvent(category: "websocket", message: "start_issued context=\(context) generation=\(generation)", generation: generation)
        updateDiagnosticsHeartbeat(lastEvent: "websocket_start_issued")
    }

    private func handleTransportConnected(generation: Int) {
        let configuration: TunnelConfiguration?
        let shouldApplySettings: Bool
        var clientIPv4: String?
        var clientIPv6: String?

        stateLock.lock()
        let isStaleCallback = generation != websocketGeneration
        let shouldIgnoreForShutdown = shutdownRequested
        configuration = self.configuration
        
        let ipChanged = (assignedIPv4 != appliedIPv4) || (assignedIPv6 != appliedIPv6)
        shouldApplySettings = (!didApplyNetworkSettings && runtimeState == .starting) || (runtimeState == .reasserting && ipChanged)
        
        if shouldApplySettings {
            clientIPv4 = assignedIPv4 ?? configuration?.tunIPv4
            clientIPv6 = assignedIPv6 ?? configuration?.tunIPv6
        }
        stateLock.unlock()

        if isStaleCallback {
            logger.info("Ignoring stale websocket connected callback generation=\(generation)")
            recordProviderEvent(category: "websocket", message: "ignore_stale_connected generation=\(generation)", generation: generation)
            return
        }
        if shouldIgnoreForShutdown {
            logger.info("Ignoring websocket connected callback generation=\(generation) because shutdown was requested")
            recordProviderEvent(category: "websocket", message: "ignore_connected_shutdown generation=\(generation)", generation: generation)
            replaceWebSocketClient(with: nil, stopCurrent: true)
            return
        }

        guard let configuration else {
            logger.error("Transport connected without runtime configuration")
            recordProviderEvent(category: "websocket", message: "connected_without_configuration generation=\(generation)", generation: generation)
            return
        }

        logger.info("Tunnel transport connected \(activityDiagnosticsDescription())")
        recordProviderEvent(category: "websocket", message: "transport_connected generation=\(generation)", generation: generation)

        if shouldApplySettings {
            let pendingAppliedIPv4 = clientIPv4
            let pendingAppliedIPv6 = clientIPv6
            logger.info("Tunnel websocket connected — applying network settings (IP changed/initial)")
            applyNetworkSettings(configuration: configuration) { [weak self] error in
                guard let self else { return }
                self.eventQueue.async { [weak self] in
                    guard let self else { return }
                    if let error {
                        logger.error("setTunnelNetworkSettings error: \(error.localizedDescription)")
                        self.recordProviderEvent(category: "settings", message: "apply_failed \(error.localizedDescription)", generation: generation)
                        self.updateRuntimeState(.failed, reason: "setTunnelNetworkSettings error")
                        self.finishStart(with: error)
                        self.replaceWebSocketClient(with: nil, stopCurrent: true)
                        return
                    }

                    self.stateLock.lock()
                    self.appliedIPv4 = pendingAppliedIPv4
                    self.appliedIPv6 = pendingAppliedIPv6
                    self.didApplyNetworkSettings = true
                    self.isReadLoopActive = true
                    self.reconnectAttempt = 0
                    self.lastTransportError = nil
                    self.stateLock.unlock()

                    self.updateRuntimeState(.connected, reason: "websocket connected and settings applied")
                    self.recordProviderEvent(category: "settings", message: "apply_success generation=\(generation)", generation: generation)
                    self.clearReadBackpressure()
                    self.startReadLoop()
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
        recordProviderEvent(category: "websocket", message: "transport_recovered generation=\(generation)", generation: generation)
        updateDiagnosticsHeartbeat(lastEvent: "transport_recovered")
        clearReadBackpressure()
        startReadLoop()
    }

    private func handleTransportDisconnected(
        generation: Int,
        wasConnected: Bool,
        reason: String
    ) {
        var stopInitiator: LocalStopInitiator?
        var isStaleCallback = false
        var shouldSuppressForShutdown = false
        var pathHandoffHint = ""

        stateLock.lock()
        stopInitiator = localStopInitiator
        isStaleCallback = generation != websocketGeneration
        shouldSuppressForShutdown = shutdownRequested
        pathHandoffHint = pathHandoffHintDescriptionLocked(now: Date())
        stateLock.unlock()

        if isStaleCallback {
            logger.info("Ignoring stale websocket disconnected callback generation=\(generation) reason=\(reason)")
            recordProviderEvent(category: "websocket", message: "ignore_stale_disconnected generation=\(generation) reason=\(reason)", generation: generation)
            return
        }

        // PR2: read native status for numeric disconnect diagnostics.
        let nativeStatus = currentWebSocketClient()?.status
        let disconnectCodeStr = nativeStatus.map { "\($0.disconnectCode)" } ?? "-"
        let stopOriginStr = nativeStatus.map { "\($0.stopOrigin)" } ?? "-"
        let activeOpsStr = nativeStatus.map { "\($0.activeOperations)" } ?? "-"

        logger.warning(
            "Tunnel websocket disconnected generation=\(generation) was_connected=\(wasConnected) reason=\(reason) stop_initiator=\(stopInitiator?.rawValue ?? "-") disconnect_code=\(disconnectCodeStr) stop_origin=\(stopOriginStr) active_ops=\(activeOpsStr) \(activityDiagnosticsDescription())"
        )
        recordProviderEvent(
            category: "websocket",
            message: "transport_disconnected generation=\(generation) was_connected=\(wasConnected) reason=\(reason) stop_initiator=\(stopInitiator?.rawValue ?? "-") disconnect_code=\(disconnectCodeStr) stop_origin=\(stopOriginStr) active_ops=\(activeOpsStr)\(pathHandoffHint)",
            generation: generation
        )
        updateDiagnosticsHeartbeat(lastEvent: "transport_disconnected")
        applyReadBackpressure(delay: sendFailureBackpressureMaxDelaySeconds, reason: "transport_disconnected")
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
            recordProviderEvent(category: "reconnect", message: "skip_disconnect_already_stopping", runtimeState: currentState.rawValue, generation: generation)
            return
        }

        if shouldSuppressForShutdown || stopInitiator == .appDisconnect || stopInitiator == .systemStop {
            logger.info(
                "Suppressing reconnect after transport disconnect because stop was already requested by \(stopInitiator?.rawValue ?? "shutdown")"
            )
            recordProviderEvent(category: "reconnect", message: "suppress_after_stop initiator=\(stopInitiator?.rawValue ?? "shutdown")", runtimeState: currentState.rawValue, generation: generation)
            updateRuntimeState(.stopping, reason: "transport disconnected after local stop request")
            return
        }

        if currentState == .starting || configuration == nil {
            let pathSatisfied: Bool
            stateLock.lock()
            pathSatisfied = isNetworkPathSatisfied
            stateLock.unlock()

            // When the path is not yet satisfied at startup, wait for network instead
            // of hard-failing. The path monitor will kick off a reconnect when
            // connectivity is restored, at which point finishStart(nil) will fire normally.
            if !pathSatisfied && configuration != nil {
                recordProviderEvent(
                    category: "reconnect",
                    message: "initial_transport_no_path reason=\(reason)",
                    runtimeState: currentState.rawValue,
                    generation: generation
                )
                switch scheduleReconnectIfPossible() {
                case .scheduled:
                    updateRuntimeState(.reasserting, reason: "initial transport, path not yet ready")
                case .waitingForNetwork:
                    updateRuntimeState(.waitingForNetwork, reason: "initial transport failure, waiting for path")
                case .unavailable:
                    updateRuntimeState(.failed, reason: "initial transport failure")
                    finishStart(with: makeError(reason))
                }
                return
            }

            recordProviderEvent(category: "reconnect", message: "initial_transport_failure reason=\(reason)", runtimeState: currentState.rawValue, generation: generation)
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
            recordProviderEvent(category: "reconnect", message: "skip_schedule_missing_configuration")
            return .unavailable
        }

        guard !shutdownRequested else {
            stateLock.unlock()
            logger.info("Skipping reconnect schedule because shutdown was requested")
            recordProviderEvent(category: "reconnect", message: "skip_schedule_shutdown")
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
            recordProviderEvent(category: "reconnect", message: "skip_schedule_disabled")
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
            recordProviderEvent(
                category: "reconnect",
                message: "waiting_for_network attempt=\(nextAttempt)",
                generation: generation,
                reconnectAttempt: nextAttempt,
                pathSatisfied: false
            )
            updateDiagnosticsHeartbeat(lastEvent: "waiting_for_network")
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
                "Reconnect attempt \(nextAttempt) exceeded configured budget \(maxAttempts). Failing tunnel."
            )
            failRuntimeTunnel(reason: "reconnect_attempts_exceeded")
            return .unavailable
        } else {
            logger.warning(
                "Scheduling reconnect attempt \(nextAttempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") after \(delaySeconds)s \(activityDiagnosticsDescription())"
            )
        }
        recordProviderEvent(
            category: "reconnect",
            message: "schedule attempt=\(nextAttempt) delay=\(delaySeconds)s budget_exceeded=\(exceededConfiguredBudget)",
            generation: generation,
            reconnectAttempt: nextAttempt,
            pathSatisfied: true
        )
        updateDiagnosticsHeartbeat(lastEvent: "reconnect_scheduled")

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
            recordProviderEvent(category: "reconnect", message: "skip_attempt_stale_or_shutdown attempt=\(attempt)", reconnectAttempt: attempt)
            return
        }

        guard currentState == .reasserting, let configuration else {
            recordProviderEvent(category: "reconnect", message: "skip_attempt_state=\(currentState.rawValue) attempt=\(attempt)", runtimeState: currentState.rawValue, reconnectAttempt: attempt)
            return
        }

        guard pathSatisfied else {
            logger.warning("Reconnect attempt \(attempt) delayed because network path is unsatisfied")
            recordProviderEvent(category: "reconnect", message: "delay_attempt_path_unsatisfied attempt=\(attempt)", runtimeState: currentState.rawValue, reconnectAttempt: attempt, pathSatisfied: false)
            updateRuntimeState(.waitingForNetwork, reason: "network path unsatisfied before reconnect")
            return
        }

        logger.warning(
            "Starting reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") \(activityDiagnosticsDescription())"
        )
        recordProviderEvent(category: "reconnect", message: "start_attempt attempt=\(attempt)", reconnectAttempt: attempt, pathSatisfied: true)
        updateDiagnosticsHeartbeat(lastEvent: "reconnect_attempt_start")
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
        recordProviderEvent(category: "failure", message: "failRuntimeTunnel reason=\(reason)", runtimeState: "failed")
        updateDiagnosticsHeartbeat(lastEvent: "failRuntimeTunnel")
        cancelPendingReconnect()
        cancelTunnelWithError(makeError(reason))
    }

    // MARK: - Network settings

    private func applyNetworkSettings(
        configuration: TunnelConfiguration,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        stateLock.lock()
        let clientIPv4 = assignedIPv4 ?? configuration.tunIPv4
        let remoteAddress = configuration.serverIP
        let clientIPv6 = assignedIPv6 ?? configuration.tunIPv6
        stateLock.unlock()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4 = NEIPv4Settings(
            addresses: [clientIPv4],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        var dnsServers = [configuration.dnsIPv4] + (configuration.dnsIPv6.map { [$0] } ?? [])
        if let custom = configuration.customDnsIPv4 {
            dnsServers = [custom] + dnsServers
            logger.info("Custom DNS configured [ipv4=\(custom)]")
        }
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        let ipv6Enabled = configuration.dnsIPv6 != nil
        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(
                addresses: [clientIPv6],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }
        settings.mtu = 1400

        logger.info(
            "Applying tunnel settings ipv4_enabled=true ipv6_enabled=\(ipv6Enabled) dns_server_count=\(dnsServers.count) mtu=1400"
        )
        recordProviderEvent(category: "settings", message: "apply_start ipv6=\(ipv6Enabled)")

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    // MARK: - Packet flow

    private func startReadLoop() {
        guard shouldReadOutboundPackets() else { return }
        if let delay = currentReadBackpressureDelay() {
            scheduleReadLoopAfterBackpressure(delay: delay)
            return
        }

        stateLock.lock()
        // PR2: exactly one process-wide pending read. A stale token
        // from an old session does not block — but only the owning
        // callback may clear it. If a read is pending (any session),
        // do not issue another.
        guard pendingReadToken == nil else {
            stateLock.unlock()
            return
        }
        let readToken = PacketReadToken(session: tunnelSession, generation: websocketGeneration)
        pendingReadToken = readToken
        isPacketReadPending = true
        stateLock.unlock()

        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }

            // PR2: only the callback that owns the pending token may
            // clear it. An old-session callback must not clobber
            // ownership of a newer read.
            self.stateLock.lock()
            let ownsPendingSlot = self.pendingReadToken == readToken
            if ownsPendingSlot {
                self.isPacketReadPending = false
                self.pendingReadToken = nil
            }
            let currentToken = PacketReadToken(session: self.tunnelSession, generation: self.websocketGeneration)
            self.stateLock.unlock()

            guard ownsPendingSlot else { return }

            // PR2: stale generation within the same session — restart
            // the current generation's read loop.
            guard readToken == currentToken else {
                self.eventQueue.async { [weak self] in
                    self?.startReadLoop()
                }
                return
            }

            guard self.shouldReadOutboundPackets() else { return }

            var queueFullPackets: Int64 = 0
            var invalidPackets: Int64 = 0
            var unknownResults: Int64 = 0
            var transportStopped = false
            let client = self.currentWebSocketClient()

            // PR1B: compute total bytes for the complete read batch
            // before sending, so packetFlowReadPackets/Bytes both
            // describe what was read from NEPacketTunnelFlow.
            let packetCount = Int64(packets.count)
            let totalBytes = packets.reduce(into: Int64.zero) {
                $0 += Int64($1.count)
            }

            // PR1B: use typed send result. Only .queueFull feeds
            // backpressure. .transportStopped breaks the batch early.
            // .invalidPacket/.unknown are counted separately.
            packetLoop: for packet in packets {
                switch client?.sendPacket(packet) ?? .transportStopped {
                case .accepted:
                    break
                case .queueFull:
                    queueFullPackets += 1
                case .transportStopped:
                    transportStopped = true
                    break packetLoop
                case .invalidPacket:
                    invalidPackets += 1
                case .unknown:
                    unknownResults += 1
                }
            }

            let backpressureDelay = self.recordPacketFlowRead(
                packetCount: packetCount,
                byteCount: totalBytes,
                sendFailures: queueFullPackets
            )

            if transportStopped {
                return
            }
            if let backpressureDelay {
                self.scheduleReadLoopAfterBackpressure(delay: backpressureDelay)
                return
            }
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

    private func shouldReadOutboundPackets() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isReadLoopActive &&
            runtimeState == .connected &&
            didApplyNetworkSettings &&
            wsClient != nil
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

    // PR2: log an invariant violation once per type.
    private func logInvariantOnce(_ invariant: ProviderInvariant) {
        stateLock.lock()
        let alreadyLogged = loggedInvariantViolations.contains(invariant)
        if !alreadyLogged {
            loggedInvariantViolations.insert(invariant)
        }
        stateLock.unlock()

        if !alreadyLogged {
            logger.error("INVARIANT_VIOLATION: \(invariant)")
            recordProviderEvent(category: "invariant", message: "violation \(invariant)")
        }
    }

    // PR2: replace the active bridge with stop-origin plumbing,
    // final status preservation, and invariant checks.
    // Order: validate generation → detach → stop/join → capture → expose.
    // Returns false if the replacement was rejected (shutdown or
    // generation mismatch). The caller must NOT start a rejected client.
    @discardableResult
    private func replaceWebSocketClient(
        with newClient: WebsocketClientBridge?,
        stopCurrent: Bool,
        stopOrigin: WebsocketStopOrigin = .swiftTunnelStop,
        expectedGeneration: Int? = nil
    ) -> Bool {
        // PR2: validate generation BEFORE detaching the current bridge.
        // A stale caller must never detach the current bridge.
        stateLock.lock()
        if let expectedGeneration, websocketGeneration != expectedGeneration {
            stateLock.unlock()
            if let newClient { _ = newClient.stop(origin: .swiftTunnelStop) }
            return false
        }
        // PR2: reject new client installation during shutdown, but
        // always allow removal (newClient == nil) so stopTunnel can
        // detach and stop the active bridge.
        if shutdownRequested, newClient != nil {
            stateLock.unlock()
            _ = newClient?.stop(origin: .swiftTunnelStop)
            return false
        }
        let previousClient = wsClient
        let generation = websocketGeneration
        wsClient = nil
        stateLock.unlock()

        // Stop and join the previous bridge.
        if stopCurrent, let previousClient {
            _ = previousClient.stop(origin: stopOrigin)
        }

        // Capture final status AFTER teardown is complete.
        if let previousClient {
            let finalStatus = previousClient.status
            stateLock.lock()
            lastNativeStatus = finalStatus
            lastNativeStatusGeneration = generation
            stateLock.unlock()

            if finalStatus.activeOperations != 0 || !finalStatus.stopCleanupCompleted {
                logInvariantOnce(.incompleteNativeTeardown)
            }
            if finalStatus.liveClients > 1 {
                logInvariantOnce(.multipleNativeClients)
            }
        }

        // PR2: bridgeReplacementOverlap removed — the previous bridge
        // is already stopped and joined before the new one is exposed,
        // so both being non-nil is a normal replacement, not an overlap.
        // liveClients > 1 (checked above via final status) is the
        // meaningful overlap invariant.

        // Revalidate before exposing.
        stateLock.lock()
        let mayExpose = !shutdownRequested && websocketGeneration == generation
        if mayExpose {
            wsClient = newClient
        }
        stateLock.unlock()

        if !mayExpose, let newClient {
            _ = newClient.stop(origin: .swiftTunnelStop)
            return false
        }

        return true
    }

    private func recordPacketFlowRead(
        packetCount: Int64,
        byteCount: Int64,
        sendFailures: Int64
    ) -> TimeInterval? {
        guard packetCount > 0 || sendFailures > 0 else { return nil }

        let now = Date()
        var previousOutboundActivityAt: Date?
        var shouldLogSendFailures = false
        var pendingSendFailures: Int64 = 0
        var totalSendFailures: Int64 = 0
        var suppressSendFailureLog = false
        var backpressureDelay: TimeInterval?

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
                consecutiveSendFailureBatches += 1
                let backoffStep = min(max(0, consecutiveSendFailureBatches - 1), 3)
                let delay = min(
                    sendFailureBackpressureMaxDelaySeconds,
                    sendFailureBackpressureBaseDelaySeconds * Double(1 << backoffStep)
                )
                let until = now.addingTimeInterval(delay)
                if readBackpressureUntil.map({ until > $0 }) ?? true {
                    readBackpressureUntil = until
                }
                backpressureDelay = delay
            }
        } else if packetCount > 0 {
            consecutiveSendFailureBatches = 0
            readBackpressureUntil = nil
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
        return backpressureDelay
    }

    private func currentReadBackpressureDelay() -> TimeInterval? {
        let now = Date()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isReadLoopActive, let until = readBackpressureUntil else {
            return nil
        }
        let delay = until.timeIntervalSince(now)
        if delay <= 0 {
            readBackpressureUntil = nil
            return nil
        }
        return min(delay, sendFailureBackpressureMaxDelaySeconds)
    }

    private func applyReadBackpressure(delay: TimeInterval, reason: String) {
        let clampedDelay = min(max(delay, sendFailureBackpressureBaseDelaySeconds), sendFailureBackpressureMaxDelaySeconds)
        let until = Date().addingTimeInterval(clampedDelay)
        stateLock.lock()
        if readBackpressureUntil.map({ until > $0 }) ?? true {
            readBackpressureUntil = until
        }
        stateLock.unlock()
        recordProviderEvent(category: "packet_flow", message: "read_backpressure reason=\(reason) delay=\(String(format: "%.2f", clampedDelay))s")
    }

    private func scheduleReadLoopAfterBackpressure(delay: TimeInterval) {
        let clampedDelay = min(max(delay, sendFailureBackpressureBaseDelaySeconds), sendFailureBackpressureMaxDelaySeconds)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.readBackpressureWorkItem = nil
            self.stateLock.unlock()
            self.startReadLoop()
        }

        stateLock.lock()
        guard isReadLoopActive, !shutdownRequested else {
            stateLock.unlock()
            return
        }
        readBackpressureWorkItem?.cancel()
        readBackpressureWorkItem = workItem
        stateLock.unlock()

        eventQueue.asyncAfter(deadline: .now() + clampedDelay, execute: workItem)
    }

    private func clearReadBackpressure() {
        stateLock.lock()
        let workItem = readBackpressureWorkItem
        readBackpressureWorkItem = nil
        readBackpressureUntil = nil
        consecutiveSendFailureBatches = 0
        stateLock.unlock()
        workItem?.cancel()
    }

    private func cancelReadBackpressure() {
        clearReadBackpressure()
    }

    private func recordPacketFlowWrite(byteCount: Int64) -> Int64 {
        let now = Date()
        var previousInboundActivityAt: Date?
        var packetCount: Int64 = 0

        stateLock.lock()
        previousInboundActivityAt = counters.lastInboundActivityAt
        counters.transportReceivedPackets += 1
        packetCount = counters.transportReceivedPackets
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
        return packetCount
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
                self?.handleNetworkPathChanged(path)
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

    private func handleNetworkPathChanged(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        let pathSummary = networkPathSummary(path)
        var shouldScheduleReconnect = false
        var attempt = 0
        var maxAttempts = 0
        var previousSummary = "unknown"
        var didPathChange = false

        stateLock.lock()
        let previous = isNetworkPathSatisfied
        previousSummary = lastNetworkPathSummary
        isNetworkPathSatisfied = isSatisfied
        lastNetworkPathSummary = pathSummary
        let now = Date()
        didPathChange = previous != isSatisfied || previousSummary != pathSummary
        if didPathChange {
            lastNetworkPathChangeAt = now
            lastNetworkPathSatisfied = isSatisfied
        }
        if isSatisfied && runtimeState == .waitingForNetwork && !shutdownRequested {
            shouldScheduleReconnect = true
            attempt = reconnectAttempt
            maxAttempts = configuration?.maxReconnectAttempts ?? 0
        }
        stateLock.unlock()

        guard didPathChange || shouldScheduleReconnect else { return }

        logger.info("Network path satisfied=\(isSatisfied) network=\(pathSummary)")
        recordProviderEvent(category: "path", message: "path_satisfied=\(isSatisfied) network=\(pathSummary)", pathSatisfied: isSatisfied)
        updateDiagnosticsHeartbeat(lastEvent: "path_satisfied=\(isSatisfied) network=\(pathSummary)")
        if didPathChange {
            applyReadBackpressure(delay: pathChangeBackpressureDelaySeconds, reason: "network_path_changed")
        }
        if shouldScheduleReconnect {
            scheduleReconnectAttempt(attempt: max(1, attempt), maxAttempts: maxAttempts)
        }
    }

    private func networkPathSummary(_ path: NWPath) -> String {
        var interfaceTypes: [String] = []
        if path.usesInterfaceType(.wifi) {
            interfaceTypes.append("wifi")
        }
        if path.usesInterfaceType(.cellular) {
            interfaceTypes.append("cellular")
        }
        if path.usesInterfaceType(.wiredEthernet) {
            interfaceTypes.append("wired")
        }
        if path.usesInterfaceType(.loopback) {
            interfaceTypes.append("loopback")
        }
        if path.usesInterfaceType(.other) {
            interfaceTypes.append("other")
        }
        if interfaceTypes.isEmpty {
            interfaceTypes = path.availableInterfaces.map { networkInterfaceTypeDescription($0.type) }
        }
        if interfaceTypes.isEmpty {
            interfaceTypes = ["none"]
        }

        var flags = ["interfaces=\(interfaceTypes.joined(separator: "+"))"]
        flags.append("expensive=\(path.isExpensive)")
        if #available(iOS 13.0, *) {
            flags.append("constrained=\(path.isConstrained)")
        }
        flags.append("ipv4=\(path.supportsIPv4)")
        flags.append("ipv6=\(path.supportsIPv6)")
        return flags.joined(separator: " ")
    }

    private func networkInterfaceTypeDescription(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wired"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
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
            recordProviderEvent(category: "reconnect", message: "skip_path_recovery_not_reconnectable attempt=\(attempt)", reconnectAttempt: attempt)
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
                "Reconnect attempt \(attempt) exceeded configured budget \(maxAttempts). Failing tunnel."
            )
            failRuntimeTunnel(reason: "reconnect_attempts_exceeded_on_path_recovery")
            return
        } else {
            logger.warning(
                "Scheduling reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(attempt)") after \(delaySeconds)s after network path recovery \(activityDiagnosticsDescription())"
            )
        }
        recordProviderEvent(
            category: "reconnect",
            message: "schedule_after_path_recovery attempt=\(attempt) delay=\(delaySeconds)s budget_exceeded=\(exceededConfiguredBudget)",
            generation: generation,
            reconnectAttempt: attempt,
            pathSatisfied: true
        )
        updateDiagnosticsHeartbeat(lastEvent: "reconnect_scheduled_after_path")

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
        #if FPTN_MEASUREMENT_BUILD
        // PR-1 (Measurement Safety): sample only Mach memory counters.
        // Avoids constructing the full TunnelRuntimeSnapshot (native
        // status query, ISO-8601 dates, string copies, packet counters)
        // on every 15-second tick during memory profiling.
        let memory = TunnelMemoryPressureSnapshot(
            residentBytes: residentMemoryBytes(),
            physFootprintBytes: physFootprintBytes()
        )
        evaluateMemoryPressure(memory: memory)
        #else
        let snapshot = currentSnapshot()
        let memory = TunnelMemoryPressureSnapshot(
            residentBytes: snapshot.memoryResidentBytes,
            physFootprintBytes: snapshot.memoryPhysFootprintBytes
        )
        updateDiagnosticsHeartbeat(snapshot: snapshot, lastEvent: "telemetry")
        evaluateMemoryPressure(memory: memory)
        #endif
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
            recordProviderEvent(category: "state", message: "\(previousState.rawValue)->\(state.rawValue) reason=\(reason)", runtimeState: state.rawValue)
        }
        if previousReasserting != newReasserting {
            logger.info("Tunnel reasserting=\(newReasserting)")
            recordProviderEvent(category: "state", message: "reasserting=\(newReasserting)", runtimeState: state.rawValue)
        }
        updateDiagnosticsHeartbeat(lastEvent: "state=\(state.rawValue)")
    }

    private func finishStart(with error: Error?) {
        var completion: ((Error?) -> Void)?

        stateLock.lock()
        completion = startCompletion
        startCompletion = nil
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        stateLock.unlock()

        recordProviderEvent(category: "startup", message: "finishStart error=\(error?.localizedDescription ?? "none")")
        updateDiagnosticsHeartbeat(lastEvent: "finishStart")
        completion?(error)
    }

    private func currentSnapshot() -> TunnelRuntimeSnapshot {
        // PR2: copy Swift fields and bridge reference under lock,
        // then query native status OUTSIDE the lock to avoid holding
        // stateLock during the C++ getStatus() call.
        let client: WebsocketClientBridge?
        let savedNativeStatus: WebsocketClientStatus?
        let savedNativeGeneration: Int?
        let state: TunnelRuntimeState
        let reasserting: Bool
        let reconnAttempt: Int
        let maxReconn: Int
        let transportError: String?
        let stopReason: String?
        let stopReasonRaw: Int?
        let stopInitiator: String?
        let inboundAt: Date?
        let outboundAt: Date?
        let readPackets: Int64
        let readBytes: Int64
        let recvPackets: Int64
        let recvBytes: Int64
        let writePackets: Int64
        let writeBytes: Int64
        let sendFailures: Int64
        let dns4: String?
        let dns6: String?
        let tun4: String?
        let tun6: String?
        let wsIdleTimeout: Int

        stateLock.lock()
        client = wsClient
        savedNativeStatus = lastNativeStatus
        savedNativeGeneration = lastNativeStatusGeneration
        state = runtimeState
        reasserting = runtimeState == .reasserting || runtimeState == .waitingForNetwork
        reconnAttempt = reconnectAttempt
        maxReconn = configuration?.maxReconnectAttempts ?? 0
        transportError = lastTransportError
        stopReason = lastStopReason
        stopReasonRaw = lastStopReasonRawValue
        stopInitiator = localStopInitiator?.rawValue
        inboundAt = counters.lastInboundActivityAt
        outboundAt = counters.lastOutboundActivityAt
        readPackets = counters.packetFlowReadPackets
        readBytes = counters.packetFlowReadBytes
        recvPackets = counters.transportReceivedPackets
        recvBytes = counters.transportReceivedBytes
        writePackets = counters.packetFlowWritePackets
        writeBytes = counters.packetFlowWriteBytes
        sendFailures = counters.websocketSendFailures
        dns4 = configuration?.dnsIPv4
        dns6 = configuration?.dnsIPv6
        tun4 = configuration?.tunIPv4
        tun6 = configuration?.tunIPv6
        wsIdleTimeout = configuration?.websocketIdleTimeoutSeconds ?? 0
        stateLock.unlock()

        // Query native status outside the lock.
        let status = client?.status ?? savedNativeStatus
        let memory = providerMemorySnapshot(status: status)

        return TunnelRuntimeSnapshot(
            runtimeState: state,
            isReasserting: reasserting,
            reconnectAttempt: reconnAttempt,
            maxReconnectAttempts: maxReconn,
            lastTransportError: transportError,
            lastStopReason: stopReason,
            lastStopReasonRawValue: stopReasonRaw,
            localStopInitiator: stopInitiator,
            lastInboundActivityAt: iso8601(inboundAt),
            lastOutboundActivityAt: iso8601(outboundAt),
            packetFlowReadPackets: readPackets,
            packetFlowReadBytes: readBytes,
            transportReceivedPackets: recvPackets,
            transportReceivedBytes: recvBytes,
            packetFlowWritePackets: writePackets,
            packetFlowWriteBytes: writeBytes,
            websocketSendFailures: sendFailures,
            dnsIPv4: dns4,
            dnsIPv6: dns6,
            tunnelIPv4: tun4,
            tunnelIPv6: tun6,
            ipv6Enabled: dns6 != nil,
            websocketRunning: status?.running ?? false,
            websocketStarted: status?.started ?? false,
            websocketIdleTimeoutSeconds: status?.idleTimeoutSeconds ?? wsIdleTimeout,
            websocketLastError: status?.lastError,
            websocketLastDisconnectReason: status?.lastDisconnectReason,
            memoryResidentBytes: memory.residentBytes,
            memoryPhysFootprintBytes: memory.physFootprintBytes,
            nativeReceivedPackets: status?.receivedPacketCount ?? 0,
            nativeReceivedBytes: status?.receivedByteCount ?? 0,
            nativeCallbackEnterCount: status?.callbackEnterCount ?? 0,
            nativeCallbackExitCount: status?.callbackExitCount ?? 0,
            nativeCallbackByteCount: status?.callbackByteCount ?? 0,
            nativeInPacketCallback: status?.inPacketCallback ?? false,
            nativeRequestedRcvbufBytes: status?.requestedRcvbufBytes ?? 0,
            nativeRequestedSndbufBytes: status?.requestedSndbufBytes ?? 0,
            nativeEffectiveRcvbufBytes: status?.effectiveRcvbufBytes ?? 0,
            nativeEffectiveSndbufBytes: status?.effectiveSndbufBytes ?? 0,
            nativeSocketBufferSetErrorCount: status?.socketBufferSetErrorCount ?? 0,
            nativeLiveClients: status?.liveClients ?? 0,
            nativeActiveReaderCoroutines: status?.activeReaderCoroutines ?? 0,
            nativeActiveSenderCoroutines: status?.activeSenderCoroutines ?? 0,
            nativeQueuedPackets: status?.queuedPackets ?? 0,
            nativeQueuedBytes: status?.queuedBytes ?? 0,
            nativeQueuedBytesPeak: status?.queuedBytesPeak ?? 0,
            nativeQueueFullCount: status?.queueFullCount ?? 0,
            nativeDisconnectCode: status?.disconnectCode.rawValue ?? 0,
            nativeStopOrigin: status?.stopOrigin.rawValue ?? 0,
            nativeActiveOperations: status?.activeOperations ?? 0,
            nativeStopCleanupCompleted: status?.stopCleanupCompleted ?? false
        )
    }

    // PR-1 (Measurement Safety): @autoclosure prevents the interpolated
    // message string from being constructed in Measurement builds.
    // The #if gate eliminates the entire call (including category string
    // literals) at compile time rather than relying on a runtime guard
    // inside TunnelDiagnosticsStore.
    private func recordProviderEvent(
        category: String,
        message: @autoclosure () -> String,
        runtimeState: String? = nil,
        generation: Int? = nil,
        reconnectAttempt: Int? = nil,
        pathSatisfied: Bool? = nil
    ) {
        #if FPTN_MEASUREMENT_BUILD
        return
        #else
        TunnelDiagnosticsStore.shared.recordProviderEvent(
            category: category,
            message: message(),
            runtimeState: runtimeState,
            generation: generation,
            reconnectAttempt: reconnectAttempt,
            pathSatisfied: pathSatisfied
        )
        #endif
    }

    // PR-1 (Measurement Safety): @autoclosure prevents interpolated
    // lastEvent strings (e.g. "state=\(state.rawValue)") from being
    // constructed in Measurement builds.
    private func updateDiagnosticsHeartbeat(lastEvent: @autoclosure () -> String) {
        #if FPTN_MEASUREMENT_BUILD
        return
        #else
        updateDiagnosticsHeartbeat(snapshot: currentSnapshot(), lastEvent: lastEvent())
        #endif
    }

    private func updateDiagnosticsHeartbeat(snapshot: TunnelRuntimeSnapshot, lastEvent: @autoclosure () -> String) {
        #if FPTN_MEASUREMENT_BUILD
        return
        #endif
        let event = lastEvent()
        let generation: Int
        let pathSatisfied: Bool
        stateLock.lock()
        generation = websocketGeneration
        pathSatisfied = isNetworkPathSatisfied
        stateLock.unlock()

        TunnelDiagnosticsStore.shared.writeHeartbeat(
            TunnelProviderHeartbeat(
                timestamp: TunnelDiagnosticsStore.now(),
                runtimeState: snapshot.runtimeState.rawValue,
                isReasserting: snapshot.isReasserting,
                generation: generation,
                reconnectAttempt: snapshot.reconnectAttempt,
                maxReconnectAttempts: snapshot.maxReconnectAttempts,
                pathSatisfied: pathSatisfied,
                websocketStarted: snapshot.websocketStarted,
                websocketRunning: snapshot.websocketRunning,
                lastTransportError: snapshot.lastTransportError ?? snapshot.websocketLastError,
                lastStopReason: snapshot.lastStopReason,
                lastEvent: event,
                lastInboundActivityAt: snapshot.lastInboundActivityAt,
                lastOutboundActivityAt: snapshot.lastOutboundActivityAt,
                packetFlowReadPackets: snapshot.packetFlowReadPackets,
                packetFlowWritePackets: snapshot.packetFlowWritePackets,
                transportReceivedPackets: snapshot.transportReceivedPackets,
                websocketSendFailures: snapshot.websocketSendFailures,
                memoryResidentBytes: snapshot.memoryResidentBytes,
                memoryPhysFootprintBytes: snapshot.memoryPhysFootprintBytes,
                localStopInitiator: snapshot.localStopInitiator,
                nativeDisconnectCode: snapshot.nativeDisconnectCode,
                nativeStopOrigin: snapshot.nativeStopOrigin
            )
        )
    }

    private func providerMemorySnapshot(status: WebsocketClientStatus?) -> TunnelMemoryPressureSnapshot {
        let swiftResident = residentMemoryBytes()
        let swiftFootprint = physFootprintBytes()
        return TunnelMemoryPressureSnapshot(
            residentBytes: nonZero(status?.memoryResidentBytes) ?? swiftResident,
            physFootprintBytes: nonZero(status?.memoryPhysFootprintBytes) ?? swiftFootprint
        )
    }

    private func nonZero(_ value: UInt64?) -> UInt64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // PR-1 (Measurement Safety): memory pressure is now telemetry-only.
    // The previous implementation destroyed the native WebSocket bridge and
    // scheduled a full reconnect at the emergency threshold (42 MiB).
    // Recreating TLS, WebSocket, queues and buffers near the memory ceiling
    // increased peak usage and obscured the original source of memory growth.
    // Both warning and emergency levels now emit a throttled OSLog entry only.
    // No bridge stop, bridge creation, reconnect scheduling, JSONL event
    // recording, or heartbeat rewrite originates from this method.
    private func evaluateMemoryPressure(
        memory: TunnelMemoryPressureSnapshot
    ) {
        switch memory.level {
        case .normal:
            return
        case .warning, .emergency:
            let now = Date()
            var shouldLog = false
            stateLock.lock()
            let elapsed = lastMemoryWarningAt.map { now.timeIntervalSince($0) } ?? .infinity
            if elapsed >= memoryWarningLogIntervalSeconds {
                lastMemoryWarningAt = now
                shouldLog = true
            }
            stateLock.unlock()
            guard shouldLog else { return }
            logger.warning("Tunnel memory pressure \(memory.level.rawValue) \(memory.description)")
        }
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
        let pathHint: String
        stateLock.lock()
        pathHint = pathHandoffHintDescriptionLocked(now: Date())
        stateLock.unlock()
        return "inbound_idle=\(inboundIdle) outbound_idle=\(outboundIdle) client_attached=\(clientAttached) read_loop_active=\(readLoopActive)\(pathHint)"
    }

    private func idleDurationDescription(from iso8601DateString: String?) -> String {
        guard let iso8601DateString,
              let date = ISO8601DateFormatter().date(from: iso8601DateString) else {
            return "never"
        }
        return "\(Int(max(0, Date().timeIntervalSince(date))))s"
    }

    private func pathHandoffHintDescriptionLocked(now: Date) -> String {
        guard let lastNetworkPathChangeAt else { return "" }

        let ageSeconds = now.timeIntervalSince(lastNetworkPathChangeAt)
        guard ageSeconds >= 0, ageSeconds <= pathHandoffHintWindowSeconds else { return "" }

        let status = lastNetworkPathSatisfied.map(String.init) ?? "unknown"
        return " likely_path_handoff=true path_change_age=\(Int(ageSeconds))s path_satisfied=\(status) network=\(lastNetworkPathSummary)"
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

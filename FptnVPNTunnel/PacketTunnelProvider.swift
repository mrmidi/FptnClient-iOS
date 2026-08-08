/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Darwin
import Network
import NetworkExtension
import os.log
import FptnSharedCore
import FptnSharedTunnel
#if FPTN_SIGNPOSTS
import os.signpost
#endif

extension NEPacketTunnelFlow: FPTNPacketFlowIO {}
extension FPTNTunnelBridge: @unchecked Sendable {}
extension FPTNApplePacketFlowAdapter: @unchecked Sendable {}

private enum TunnelRuntimeState: String, Codable {
    case idle
    case starting
    case connected
    case reasserting
    case waitingForNetwork
    case stopping
    case failed

    // PR3: stable numeric codes for binary snapshot.
    var binaryCode: UInt32 {
        switch self {
        case .idle: return 0
        case .starting: return 1
        case .connected: return 2
        case .reasserting: return 3
        case .waitingForNetwork: return 4
        case .stopping: return 5
        case .failed: return 6
        }
    }
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

    // PR3: stable numeric codes for binary snapshot (not hashValue).
    var binaryCode: UInt16 {
        switch self {
        case .appDisconnect: return 1
        case .providerFailure: return 2
        case .systemStop: return 3
        }
    }
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
    let nativeOutboundAdmissionCopyBytes: UInt64
    let nativeLivePacketLeases: UInt64
    let nativePeakPacketLeases: UInt64
}

private struct TunnelConfiguration {
    let episodeID: UUID
    let serverIP: String
    let serverPort: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String?
    let customDnsIPv4: String?
    let sni: String
    let md5Fingerprint: String
    let logLevel: String
    let dataPlaneMode: TunnelDataPlaneMode
    let websocketStrategy: String
    let websocketIdleTimeoutSeconds: Int
    let reconnectEnabled: Bool
    let maxReconnectAttempts: Int
    let reconnectDelaySeconds: Int
    let tunIPv4: String
    let tunIPv4Gateway: String
    let tunIPv6: String

    init(providerConfiguration: [String: Any]) throws {
        guard let payloadData = providerConfiguration[TunnelProviderConfigurationKey.startupV1] as? Data else {
            throw TunnelConfigError.missingData
        }
        guard payloadData.count <= TunnelStartupConfigurationV1.maximumEncodedSize else {
            throw TunnelConfigError.payloadTooLarge
        }
        let startupV1: TunnelStartupConfigurationV1
        do {
            startupV1 = try JSONDecoder().decode(TunnelStartupConfigurationV1.self, from: payloadData)
        } catch let payloadError as TunnelStartupPayloadError {
            if case .unsupportedDataPlaneMode(let rawValue) = payloadError {
                throw TunnelConfigError.unsupportedDataPlaneMode(rawValue: rawValue, schemaVersion: 1)
            }
            throw payloadError
        }
        // Clamp here as well as in the app. The app's SettingsService already
        // refuses to hand a release build a non-release-safe mode, but this
        // process is the one that actually routes packets, and the payload
        // reaching it is whatever was last saved into the NE configuration —
        // which outlives the app that wrote it. A debug install upgraded in
        // place can leave `flow_proxy` sitting in saved preferences, and
        // honouring it would send every flow out of the device while the UI
        // reported a healthy tunnel. Landing on l3Tunnel is the safe answer,
        // not split.
        #if DEBUG
        self.dataPlaneMode = startupV1.dataPlaneMode
        #else
        self.dataPlaneMode = startupV1.dataPlaneMode.isReleaseSafe
            ? startupV1.dataPlaneMode
            : .l3Tunnel
        #endif
        self.episodeID = startupV1.episodeID
        self.serverIP = startupV1.serverHost
        self.serverPort = startupV1.serverPort
        self.accessToken = startupV1.accessToken
        self.dnsIPv4 = startupV1.dnsIPv4
        self.dnsIPv6 = startupV1.dnsIPv6
        self.customDnsIPv4 = startupV1.customDnsIPv4
        self.sni = startupV1.sni
        self.md5Fingerprint = startupV1.md5Fingerprint
        self.logLevel = startupV1.logLevel.rawValue
        self.websocketIdleTimeoutSeconds = startupV1.websocketIdleTimeoutSeconds
        switch startupV1.recoveryPolicy {
        case .none:
            self.reconnectEnabled = false
            self.maxReconnectAttempts = 0
            self.reconnectDelaySeconds = 0
        case .automatic(let autoPolicy):
            self.reconnectEnabled = true
            self.maxReconnectAttempts = autoPolicy.sameServerAttempts
            self.reconnectDelaySeconds = autoPolicy.reconnectDelaySeconds
        }
        self.tunIPv4 = "10.8.0.2"
        self.tunIPv4Gateway = "10.8.0.1"
        self.tunIPv6 = "fd00::1"
        self.websocketStrategy = "\(startupV1.censorshipStrategy.rawValue);idle_timeout=\(startupV1.websocketIdleTimeoutSeconds);tun_ipv6=\(self.tunIPv6)"
    }
}

private enum TunnelConfigError: Error {
    case missingData
    case payloadTooLarge
    case unsupportedDataPlaneMode(rawValue: String, schemaVersion: Int)
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
    // PR3: protects latestEventSequence and physicalFootprintPeakBytes
    // which can be written from native callbacks on different threads.
    private let diagnosticsLock = NSLock()

    // PR3: binary flight recorder + lifecycle snapshot store.
    private var flightRecorder: TunnelFlightRecorder?
    private var lifecycleStore: TunnelLifecycleSnapshotStore?
    private var tunnelSessionToken: UInt64 = 0
    private var tunnelStartedMachTime: UInt64 = 0
    private var physicalFootprintPeakBytes: UInt64 = 0
    private var latestEventSequence: UInt64 = 0

    // Exact session upload accounting + sampled peak bandwidth. All under
    // diagnosticsLock. See exactSessionUploadBytes()/updateTrafficRateTracking()
    // — upload totals are never reconstructed from periodic deltas (that
    // loses bytes across a reconnect); each websocket generation's final
    // native admission count is folded in exactly once, in
    // replaceWebSocketClient, at the same point lastNativeStatus is already
    // captured.
    private var completedGenerationUploadBytes: UInt64 = 0
    private var lastFinalizedUploadGeneration: Int = -1
    private var peakUploadBytesPerSecond: UInt64 = 0
    private var peakDownloadBytesPerSecond: UInt64 = 0
    private var previousSessionUploadBytes: UInt64 = 0
    private var previousSessionDownloadBytes: Int64 = 0
    private var previousRateSampleMachTime: UInt64 = 0  // 0 = "no baseline yet"

    // PR3A: Instruments signpost state (Debug/Measurement only).
    // Protected by signpostLock — never hold stateLock while emitting.
    #if FPTN_SIGNPOSTS
    private let signpostLock = NSLock()
    private var startupSignpost: OSSignpostIntervalState?
    private var bridgeSignpost: (generation: Int, id: OSSignpostID, state: OSSignpostIntervalState)?
    private var teardownSignpost: (generation: Int, id: OSSignpostID, state: OSSignpostIntervalState)?
    private var shutdownSignpost: OSSignpostIntervalState?
    private var reconnectSignpost: (attempt: Int, id: OSSignpostID, state: OSSignpostIntervalState)?
    private var readLoopSignpost: OSSignpostIntervalState?
    #endif

    private var wsClient: WebsocketClientBridge?
    private var flowBridge: FPTNTunnelBridge?
    private var flowAdapter: FPTNApplePacketFlowAdapter?
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

    private func currentDiagnosticContext(
        wsGen: Int? = nil,
        reconnectAtt: Int? = nil
    ) -> DiagnosticLogContext {
        let ep = configuration?.episodeID
        let gen = wsGen ?? websocketGeneration
        let rec = reconnectAtt ?? reconnectAttempt
        return DiagnosticLogContext(
            episodeID: ep,
            websocketGeneration: gen > 0 ? gen : nil,
            reconnectAttempt: rec > 0 ? rec : nil
        )
    }
    // PR4b: track last recorded pressure level so warning→emergency
    // transitions are always recorded even inside the log throttle.
    private var lastRecordedMemoryLevel: TunnelMemoryPressureLevel = .normal
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
    // The durable binary lifecycle snapshot is written on this coarse cadence.
    private let telemetryIntervalSeconds: TimeInterval = 15
    // Peak bandwidth is sampled on this fine cadence so a short burst (e.g. a
    // speedtest) isn't diluted into a 15s window average. This runs on a
    // provider-owned timer so it keeps sampling while the app is backgrounded.
    private let rateSampleIntervalSeconds: TimeInterval = 1
    // Confined to eventQueue (the telemetry timer's queue); no lock needed.
    private var telemetryTickCount: UInt64 = 0

    deinit {
        recordProviderEvent(category: "lifecycle", message: "PacketTunnelProvider deinit", flightEvent: .tunnelStopped)
        updateDiagnosticsHeartbeat(lastEvent: "deinit")
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        #if FPTN_SIGNPOSTS
        signpostLock.lock()
        startupSignpost = TunnelSignposts.beginTunnelStartup()
        signpostLock.unlock()
        #endif
        bootstrapLogging()
        // First line of every tunnel session: which native framework actually
        // loaded. A Release app can link a Debug framework, and until this was
        // logged the only way to find out was to disassemble the binary.
        if NativeBuildInfo.isPerformanceRepresentative {
            logger.info("Build: \(NativeBuildInfo.logLine)")
        } else {
            logger.warning("Build: \(NativeBuildInfo.logLine)")
        }
        TunnelCrashSignalInstaller.installIfPossible()

        // PR3: initialize binary flight recorder + lifecycle snapshot store.
        var didCreateFlightRecorder = false
        if flightRecorder == nil,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: "group.net.mrmidi.FptnVPN") {
            let diagDir = container.appendingPathComponent("diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
            let ringPath = diagDir.appendingPathComponent("flight-ring.bin").path
            let snapPath = diagDir.appendingPathComponent("lifecycle-snapshot.bin").path
            flightRecorder = TunnelFlightRecorder(path: ringPath)
            lifecycleStore = TunnelLifecycleSnapshotStore(path: snapPath)
            didCreateFlightRecorder = true
        }

        tunnelStartedMachTime = mach_continuous_time()
        diagnosticsLock.lock()
        physicalFootprintPeakBytes = 0
        latestEventSequence = 0
        completedGenerationUploadBytes = 0
        lastFinalizedUploadGeneration = -1
        peakUploadBytesPerSecond = 0
        peakDownloadBytesPerSecond = 0
        previousSessionUploadBytes = 0
        previousSessionDownloadBytes = 0
        previousRateSampleMachTime = 0
        diagnosticsLock.unlock()
        logger.info("PacketTunnelProvider startTunnel")

        if didCreateFlightRecorder {
            let identity = ProviderProcessIdentity.shared
            if let seq = flightRecorder?.record(.processStarted,
                value0: identity.pid,
                value1: UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
                value2: identity.processSequence,
                synchronize: true), seq > 0 {
                diagnosticsLock.lock()
                latestEventSequence = seq
                diagnosticsLock.unlock()
            }
        }

        recordProviderEvent(category: "lifecycle", message: "startTunnel", flightEvent: .startTunnel)
        _ = options

        let runtimeConfig: TunnelConfiguration
        if let config = protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfig = config.providerConfiguration {
            do {
                runtimeConfig = try TunnelConfiguration(providerConfiguration: providerConfig)
            } catch TunnelConfigError.unsupportedDataPlaneMode(let rawValue, let schemaVersion) {
                recordProviderEvent(category: "error", message: "unsupportedDataPlaneMode rawValue=\(rawValue) schemaVersion=\(schemaVersion)", flightEvent: .unsupportedDataPlaneMode)
                let err = makeError("Unsupported data plane mode '\(rawValue)' (schema version \(schemaVersion))")
                logger.error("startTunnel failed: \(err.localizedDescription)")
                #if FPTN_SIGNPOSTS
                endStartupSignpost()
                #endif
                completionHandler(err)
                return
            } catch {
                let err = makeError("Missing or incomplete providerConfiguration: \(error)")
                logger.error("startTunnel failed: \(err.localizedDescription)")
                #if FPTN_SIGNPOSTS
                endStartupSignpost()
                #endif
                completionHandler(err)
                return
            }
        } else {
            let err = makeError("Missing or incomplete providerConfiguration")
            logger.error("startTunnel failed: \(err.localizedDescription)")
            #if FPTN_SIGNPOSTS
            endStartupSignpost()
            #endif
            completionHandler(err)
            return
        }

        tunnelSessionToken = Self.sessionToken(for: runtimeConfig.episodeID)
        if let seq = flightRecorder?.recordForSession(.startTunnel, sessionToken: tunnelSessionToken, synchronize: true), seq > 0 {
            diagnosticsLock.lock()
            latestEventSequence = seq
            diagnosticsLock.unlock()
        }

        setTunnelLogLevel(rawValue: runtimeConfig.logLevel)
        logger.info("Tunnel started (level=\(runtimeConfig.logLevel), mode=\(runtimeConfig.dataPlaneMode.rawValue))")
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
        tunnelSession &+= 1
        websocketGeneration = 0
        didApplyNetworkSettings = false
        isReadLoopActive = false
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
        loggedInvariantViolations.removeAll()
        lastNativeStatus = nil
        lastNativeStatusGeneration = nil
        stateLock.unlock()

        updateRuntimeState(.starting, reason: "startTunnel")
        updateDiagnosticsHeartbeat(lastEvent: "startTunnel")
        startPathMonitor()
        scheduleStartTimeout(seconds: 15)

        switch runtimeConfig.dataPlaneMode {
        case .l3Tunnel:
            startWebSocket(using: runtimeConfig, context: "initial_start")
        case .split:
            guard FPTNTunnelBridge.isFlowSupported() else {
                let err = makeError("Split routing is not supported in this build")
                logger.error("startTunnel failed: \(err.localizedDescription)")
                finishStart(with: err)
                return
            }
            // Both planes run in one session, so start exactly as l3Tunnel
            // does. The lwIP side is brought up in handleTransportConnected,
            // once there is a transport to hand it for fptn-verdict traffic.
            startWebSocket(using: runtimeConfig, context: "initial_start")
        case .flowProxy:
            guard FPTNTunnelBridge.isFlowSupported() else {
                let err = makeError("FlowProxy data plane is not supported in this build")
                logger.error("startTunnel failed: \(err.localizedDescription)")
                finishStart(with: err)
                return
            }

            // Resolver reachability is decided in applyNetworkSettings, which
            // filters per address and fails with a precise message if nothing
            // usable survives. The prefix test that used to live here only
            // covered 10/8, 192.168/16, 127/8 and 169.254/16 — it missed
            // 172.16/12 entirely and never looked at the IPv6 resolver, which
            // was the address actually breaking name resolution.

            let bridge = FPTNTunnelBridge(tunIPv4: runtimeConfig.tunIPv4, tunIPv6: runtimeConfig.tunIPv6, mtu: 1400)
            let adapter = FPTNApplePacketFlowAdapter(packetFlow: packetFlow, consumer: bridge)
            bridge.setEgressAdapter(adapter)

            do {
                try bridge.start()
            } catch {
                let err = makeError("Failed to start FlowProxy bridge: \(error.localizedDescription)")
                logger.error("startTunnel failed: \(err.localizedDescription)")
                finishStart(with: err)
                return
            }

            adapter.start()

            self.flowBridge = bridge
            self.flowAdapter = adapter

            applyNetworkSettings(configuration: runtimeConfig) { [weak self] err in
                guard let self else { return }
                if let err {
                    // Adapter first: stop feeding ingress before the engine
                    // goes away, matching the order used by stopTunnel.
                    adapter.stop()
                    bridge.stop()
                    self.flowAdapter = nil
                    self.flowBridge = nil
                    self.finishStart(with: err)
                } else {
                    self.updateRuntimeState(.connected, reason: "flowProxy started")
                    self.finishStart(with: nil)
                }
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let description = describeStopReason(reason.rawValue)
        let initiator = currentOrDefaultStopInitiator()
        #if FPTN_SIGNPOSTS
        signpostLock.lock()
        shutdownSignpost = TunnelSignposts.beginTunnelShutdown()
        signpostLock.unlock()
        #endif

        stateLock.lock()
        shutdownRequested = true
        lastStopReasonRawValue = Int(reason.rawValue)
        lastStopReason = description
        let wasReadLoopActive = isReadLoopActive
        isReadLoopActive = false
        // PR2: do NOT clear isPacketReadPending — the outstanding
        // readPackets callback still exists and owns the slot.
        stateLock.unlock()

        // PR3A: end ReadLoopLifetime on true→false transition, outside lock.
        #if FPTN_SIGNPOSTS
        if wasReadLoopActive {
            signpostLock.lock()
            if let sp = readLoopSignpost { TunnelSignposts.endReadLoopLifetime(sp); readLoopSignpost = nil }
            signpostLock.unlock()
        }
        #endif

        logger.warning(
            "PacketTunnelProvider stopTunnel systemReason=\(TunnelStopReasonDescription.describe(rawValue: reason.rawValue)) recordedInitiator=\(initiator.rawValue)\(currentDiagnosticContext().formatted())"
        )
        recordProviderEvent(
            category: "lifecycle",
            message: "stopTunnel systemReason=\(TunnelStopReasonDescription.describe(rawValue: reason.rawValue)) recordedInitiator=\(initiator.rawValue)",
            runtimeState: "stopping",
            flightEvent: .stopTunnelEntered
        )
        updateDiagnosticsHeartbeat(lastEvent: "stopTunnel")

        cancelStartTimeout()
        cancelPendingReconnect()
        cancelReadBackpressure()
        stopPathMonitor()
        stopTelemetry()
        finishStart(with: makeError("Tunnel stopped before startup completed"))

        if let adapter = flowAdapter {
            flowAdapter = nil
            adapter.stop()
        }
        if let bridge = flowBridge {
            flowBridge = nil
            bridge.stop()
        }

        replaceWebSocketClient(with: nil, stopCurrent: true)
        // Final synchronized write, after the last generation's exact upload
        // total has been finalized above — without this, the persisted
        // "last session" totals can be stale by up to one telemetry
        // interval on an otherwise orderly stop.
        writeLifecycleSnapshot(synchronize: true)

        #if FPTN_SIGNPOSTS
        signpostLock.lock()
        if let sp = shutdownSignpost {
            TunnelSignposts.endTunnelShutdown(sp)
            shutdownSignpost = nil
        }
        signpostLock.unlock()
        #endif
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
            setTunnelLogLevel(rawValue: message.logLevel?.rawValue)
            logger.info("Tunnel log level updated via IPC: \(message.logLevel?.rawValue ?? "info")")
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "log_level_updated")))
        case .ping:
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "pong")))
        case .prepareStop:
            if message.initiator == .appDisconnect {
                stateLock.lock()
                localStopInitiator = .appDisconnect
                shutdownRequested = true
                let wasReadLoopActive = isReadLoopActive
                isReadLoopActive = false
                stateLock.unlock()
                // PR3A: end ReadLoopLifetime outside lock.
                #if FPTN_SIGNPOSTS
                if wasReadLoopActive {
                    signpostLock.lock()
                    if let sp = readLoopSignpost { TunnelSignposts.endReadLoopLifetime(sp); readLoopSignpost = nil }
                    signpostLock.unlock()
                }
                #endif
                cancelPendingReconnect()
                cancelReadBackpressure()
                logger.info("Marked local stop initiator via IPC: app_disconnect; reconnect will be suppressed")
                recordProviderEvent(category: "ipc", message: "prepare_stop initiator=app_disconnect", flightEvent: .stopTunnelEntered)
                updateDiagnosticsHeartbeat(lastEvent: "prepare_stop")
            }
            completionHandler?(encodeResponse(TunnelControlResponse(ok: true, message: "stop_initiator_recorded")))
        case .getStatus:
            completionHandler?(try? JSONEncoder().encode(currentStatusSnapshot()))
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
            reconnectAttempt: snapshot.reconnectAttempt,
            flightEvent: .pathChanged
        )
        writeLifecycleSnapshot()
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
            reconnectAttempt: snapshot.reconnectAttempt,
            flightEvent: .pathChanged
        )
        writeLifecycleSnapshot()

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
            recordProviderEvent(category: "websocket", message: "skip_start context=\(context) shutdown=true", flightEvent: .bridgeStopRequested)
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
            packetBatchCallback: { [weak self] batch in
                self?.handleIncomingPacketBatchFromServer(batch, generation: generation)
            },
            connectedCallback: { [weak self] in
                guard let self else { return }
                self.recordProviderEvent(category: "websocket_callback", message: "connected_callback_enter generation=\(generation)", generation: generation, flightEvent: .bridgeConnected)
                self.eventQueue.async { [weak self] in
                    self?.handleTransportConnected(generation: generation)
                }
            },
            disconnectedCallback: { [weak self] wasConnected, reason in
                guard let self else { return }
                self.recordProviderEvent(category: "websocket_callback", message: "disconnected_callback_enter generation=\(generation) was_connected=\(wasConnected) reason=\(reason)", generation: generation, flightEvent: .transportDisconnected)
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
            recordProviderEvent(category: "websocket", message: "start_failed context=\(context) generation=\(generation)", generation: generation, flightEvent: .bridgeStopRequested)
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
        recordProviderEvent(category: "websocket", message: "start_issued context=\(context) generation=\(generation)", generation: generation, flightEvent: .bridgeStartRequested)
        updateDiagnosticsHeartbeat(lastEvent: "websocket_start_issued")
    }

    // MARK: - Split routing

    /// Hardcoded verification policy. `2ip.ru` echoes the caller's public IP,
    /// so a single page load proves which plane carried the flow: it must show
    /// this device's own address while every other site shows the server's.
    /// `mail.ru` must fail *immediately* rather than hang, which is what
    /// distinguishes reject from drop.
    ///
    /// Replaced by the geosite loader later; there is deliberately no UI for
    /// editing these yet.
    private static let splitDirectDomains = ["domain:2ip.ru"]
    private static let splitRejectDomains = ["domain:mail.ru"]
    private static let splitDropDomains: [String] = []

    /// Brings up lwIP for split mode. Idempotent: a reconnect re-points the
    /// transport but must not rebuild the stack, or every live direct flow
    /// would die with it.
    private func ensureSplitPlaneStarted(configuration: TunnelConfiguration) -> Bool {
        if flowBridge != nil {
            return true
        }

        // Resolvers are pinned to the fptn verdict so the server's own DNS is
        // reachable through the tunnel — that is what makes split mode work
        // without a custom resolver.
        var resolvers: [String] = [configuration.dnsIPv4]
        if let dnsIPv6 = configuration.dnsIPv6 { resolvers.append(dnsIPv6) }
        if let custom = configuration.customDnsIPv4 { resolvers.append(custom) }

        guard let bridge = FPTNTunnelBridge(
            splitWithTunIPv4: configuration.tunIPv4,
            tunIPv6: configuration.tunIPv6,
            mtu: 1400,
            serverIP: configuration.serverIP,
            serverPort: Int32(configuration.serverPort),
            directDomains: Self.splitDirectDomains,
            rejectDomains: Self.splitRejectDomains,
            dropDomains: Self.splitDropDomains,
            tunnelResolvers: resolvers
        ) else {
            logger.error("Failed to create the split routing bridge")
            recordProviderEvent(category: "error", message: "split_bridge_create_failed", flightEvent: .unsupportedDataPlaneMode)
            return false
        }

        let adapter = FPTNApplePacketFlowAdapter(packetFlow: packetFlow, consumer: bridge)
        bridge.setEgressAdapter(adapter)
        do {
            try bridge.start()
        } catch {
            logger.error("Failed to start the split routing bridge: \(error.localizedDescription)")
            recordProviderEvent(category: "error", message: "split_bridge_start_failed", flightEvent: .unsupportedDataPlaneMode)
            return false
        }
        adapter.start()

        flowBridge = bridge
        flowAdapter = adapter
        logger.info("Split routing plane started [direct=\(Self.splitDirectDomains.count) reject=\(Self.splitRejectDomains.count) resolvers=\(resolvers.count)]")
        recordProviderEvent(category: "flow", message: "split_plane_started", flightEvent: .tunnelConnected)
        return true
    }

    /// Points the split plane at the current generation's websocket, or clears
    /// it. Must be cleared *before* a bridge is released: the native setter
    /// blocks until no ingress call still holds the old pointer.
    private func updateSplitTransport(_ client: WebsocketClientBridge?) {
        guard let flowBridge else { return }
        flowBridge.setSplitTransport(client?.splitTransportHandle)
        logger.debug("Split transport \(client == nil ? "cleared" : "attached")")
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
            recordProviderEvent(category: "websocket", message: "ignore_stale_connected generation=\(generation)", generation: generation, flightEvent: .bridgeConnected)
            return
        }
        if shouldIgnoreForShutdown {
            logger.info("Ignoring websocket connected callback generation=\(generation) because shutdown was requested")
            recordProviderEvent(category: "websocket", message: "ignore_connected_shutdown generation=\(generation)", generation: generation, flightEvent: .bridgeStopRequested)
            replaceWebSocketClient(with: nil, stopCurrent: true)
            return
        }

        guard let configuration else {
            logger.error("Transport connected without runtime configuration")
            recordProviderEvent(category: "websocket", message: "connected_without_configuration generation=\(generation)", generation: generation, flightEvent: .bridgeConnected)
            return
        }

        // Split mode: bring lwIP up (once) and hand it this generation's
        // transport before any settings are applied, so the first packet the
        // OS sends already has somewhere to go.
        if configuration.dataPlaneMode == .split {
            guard ensureSplitPlaneStarted(configuration: configuration) else {
                let err = makeError("Failed to start the split routing plane")
                updateRuntimeState(.failed, reason: "split plane start failed")
                finishStart(with: err)
                replaceWebSocketClient(with: nil, stopCurrent: true)
                return
            }
            stateLock.lock()
            let currentClient = wsClient
            stateLock.unlock()
            updateSplitTransport(currentClient)
        }

        logger.info("Tunnel transport connected \(activityDiagnosticsDescription())")
        #if FPTN_SIGNPOSTS
        signpostLock.lock(); TunnelSignposts.transportConnected(generation: generation); signpostLock.unlock()
        #endif
        recordProviderEvent(category: "websocket", message: "transport_connected generation=\(generation)", generation: generation, flightEvent: .bridgeConnected)

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
                        self.recordProviderEvent(category: "settings", message: "apply_failed \(error.localizedDescription)", generation: generation, flightEvent: .bridgeStopRequested)
                        self.updateRuntimeState(.failed, reason: "setTunnelNetworkSettings error")
                        self.finishStart(with: error)
                        self.replaceWebSocketClient(with: nil, stopCurrent: true)
                        return
                    }

                    self.stateLock.lock()
                    self.appliedIPv4 = pendingAppliedIPv4
                    self.appliedIPv6 = pendingAppliedIPv6
                    self.didApplyNetworkSettings = true
                    let shouldBeginReadLoop = !self.isReadLoopActive
                    self.isReadLoopActive = true
                    self.reconnectAttempt = 0
                    self.lastTransportError = nil
                    self.stateLock.unlock()

                    // PR3A: begin ReadLoopLifetime only on false→true transition.
                    #if FPTN_SIGNPOSTS
                    if shouldBeginReadLoop {
                        self.signpostLock.lock()
                        self.readLoopSignpost = TunnelSignposts.beginReadLoopLifetime()
                        self.signpostLock.unlock()
                    }
                    #endif

                    self.updateRuntimeState(.connected, reason: "websocket connected and settings applied")
                    self.recordProviderEvent(category: "settings", message: "apply_success generation=\(generation)", generation: generation, flightEvent: .tunnelConnected)
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
        recordProviderEvent(category: "websocket", message: "transport_recovered generation=\(generation)", generation: generation, flightEvent: .bridgeConnected)
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
            recordProviderEvent(category: "websocket", message: "ignore_stale_disconnected generation=\(generation) reason=\(reason)", generation: generation, flightEvent: .transportDisconnected)
            return
        }

        // PR2: read native status for numeric disconnect diagnostics.
        let nativeStatus = currentWebSocketClient()?.status
        let disconnectCode = nativeStatus?.disconnectCode.rawValue ?? 0
        let stopOrigin = nativeStatus?.stopOrigin.rawValue ?? 0
        let activeOps = nativeStatus?.activeOperations ?? 0

        logger.warning(
            "Tunnel websocket disconnected generation=\(generation) was_connected=\(wasConnected) reason=\(reason) stop_initiator=\(stopInitiator?.rawValue ?? "-") disconnect_code=\(disconnectCode) stop_origin=\(stopOrigin) active_ops=\(activeOps) \(activityDiagnosticsDescription())"
        )
        recordProviderEvent(
            category: "websocket",
            message: "transport_disconnected generation=\(generation) was_connected=\(wasConnected) reason=\(reason) stop_initiator=\(stopInitiator?.rawValue ?? "-") disconnect_code=\(disconnectCode) stop_origin=\(stopOrigin) active_ops=\(activeOps)\(pathHandoffHint)",
            generation: generation,
            flightEvent: .transportDisconnected,
            flightFlags: wasConnected ? 1 : 0,
            value0: UInt64(disconnectCode),
            value1: UInt64(stopOrigin),
            value2: UInt64(activeOps)
        )
        updateDiagnosticsHeartbeat(lastEvent: "transport_disconnected")
        #if FPTN_SIGNPOSTS
        signpostLock.lock(); TunnelSignposts.transportDisconnected(generation: generation); signpostLock.unlock()
        #endif
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
            recordProviderEvent(category: "reconnect", message: "skip_disconnect_already_stopping", runtimeState: currentState.rawValue, generation: generation, flightEvent: .stopTunnelEntered)
            return
        }

        if shouldSuppressForShutdown || stopInitiator == .appDisconnect || stopInitiator == .systemStop {
            logger.info(
                "Suppressing reconnect after transport disconnect because stop was already requested by \(stopInitiator?.rawValue ?? "shutdown")"
            )
            recordProviderEvent(category: "reconnect", message: "suppress_after_stop initiator=\(stopInitiator?.rawValue ?? "shutdown")", runtimeState: currentState.rawValue, generation: generation, flightEvent: .stopTunnelEntered)
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
                    generation: generation,
                    flightEvent: .reconnectScheduled
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

            recordProviderEvent(category: "reconnect", message: "initial_transport_failure reason=\(reason)", runtimeState: currentState.rawValue, generation: generation, flightEvent: .reconnectScheduled)
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
            recordProviderEvent(category: "reconnect", message: "skip_schedule_missing_configuration", flightEvent: .reconnectScheduled)
            return .unavailable
        }

        guard !shutdownRequested else {
            stateLock.unlock()
            logger.info("Skipping reconnect schedule because shutdown was requested")
            recordProviderEvent(category: "reconnect", message: "skip_schedule_shutdown", flightEvent: .reconnectScheduled)
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
            recordProviderEvent(category: "reconnect", message: "skip_schedule_disabled", flightEvent: .reconnectScheduled)
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
                pathSatisfied: false,
                flightEvent: .reconnectScheduled
            )
            updateDiagnosticsHeartbeat(lastEvent: "waiting_for_network")
            return .waitingForNetwork
        }

        // PR3A: end previous ReconnectDelay before replacing.
        #if FPTN_SIGNPOSTS
        endReconnectDelaySignpost()
        #endif
        reconnectWorkItem?.cancel()

        workItem = DispatchWorkItem { [weak self] in
            self?.performReconnectAttempt(expectedGeneration: generation)
        }
        reconnectWorkItem = workItem
        stateLock.unlock()

        // PR3A: begin ReconnectDelay after work item is accepted.
        #if FPTN_SIGNPOSTS
        signpostLock.lock()
        let rsp = TunnelSignposts.beginReconnectDelay(attempt: nextAttempt)
        reconnectSignpost = (attempt: nextAttempt, id: rsp.0, state: rsp.1)
        signpostLock.unlock()
        #endif

        if exceededConfiguredBudget {
            #if FPTN_SIGNPOSTS
            endReconnectDelaySignpost()
            #endif
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
            pathSatisfied: true,
            flightEvent: .reconnectScheduled,
            flightFlags: 1,
            value0: UInt64(nextAttempt),
            value1: UInt64(delaySeconds)
        )
        updateDiagnosticsHeartbeat(lastEvent: "reconnect_scheduled")

        if let workItem {
            eventQueue.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        }

        return .scheduled
    }

    private func performReconnectAttempt(expectedGeneration: Int) {
        // PR3A: end ReconnectDelay when the attempt starts.
        #if FPTN_SIGNPOSTS
        endReconnectDelaySignpost()
        #endif
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
            recordProviderEvent(category: "reconnect", message: "skip_attempt_stale_or_shutdown attempt=\(attempt)", reconnectAttempt: attempt, flightEvent: .reconnectStarted)
            return
        }

        guard currentState == .reasserting, let configuration else {
            recordProviderEvent(category: "reconnect", message: "skip_attempt_state=\(currentState.rawValue) attempt=\(attempt)", runtimeState: currentState.rawValue, reconnectAttempt: attempt, flightEvent: .reconnectStarted)
            return
        }

        guard pathSatisfied else {
            logger.warning("Reconnect attempt \(attempt) delayed because network path is unsatisfied")
            recordProviderEvent(category: "reconnect", message: "delay_attempt_path_unsatisfied attempt=\(attempt)", runtimeState: currentState.rawValue, reconnectAttempt: attempt, pathSatisfied: false, flightEvent: .reconnectScheduled)
            updateRuntimeState(.waitingForNetwork, reason: "network path unsatisfied before reconnect")
            return
        }

        logger.warning(
            "Starting reconnect attempt \(attempt)\(maxAttempts == 0 ? " (unlimited)" : "/\(maxAttempts)") \(activityDiagnosticsDescription())"
        )
        recordProviderEvent(category: "reconnect", message: "start_attempt attempt=\(attempt)", reconnectAttempt: attempt, pathSatisfied: true, flightEvent: .reconnectStarted)
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
        recordProviderEvent(category: "failure", message: "failRuntimeTunnel reason=\(reason)", runtimeState: "failed", flightEvent: .tunnelStopped)
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
        let monitor = pathMonitor
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

        var ipv6Enabled = configuration.dnsIPv6 != nil
        // flowProxy only, deliberately. It routes everything direct, so the
        // server's resolvers are unreachable and have to be filtered out.
        // Split mode reaches them through the tunnel — a pinned classifier rule
        // sends resolver traffic to the fptn verdict — so it keeps them, which
        // is the whole reason split mode needs no custom DNS.
        if configuration.dataPlaneMode == .flowProxy {
            let pathSupportsIPv6 = monitor?.currentPath.supportsIPv6 ?? false

            // Keep the server's resolvers wherever they can actually be
            // reached — only drop the ones flow mode cannot use.
            let unreachable = dnsServers.filter { !Self.isFlowReachableResolver($0) }
            dnsServers.removeAll { !Self.isFlowReachableResolver($0) }
            if !pathSupportsIPv6 {
                dnsServers.removeAll { IPv6Address($0) != nil }
            }
            if !unreachable.isEmpty {
                logger.warning(
                    "Dropped unreachable resolver(s) for flow mode [servers=\(unreachable.joined(separator: ","))]"
                )
            }

            guard !dnsServers.isEmpty else {
                let err = makeError(
                    "No reachable DNS server for the flow data plane — every server-supplied resolver is private, loopback or link-local, which flow mode cannot route. Configure a custom DNS in Settings."
                )
                logger.error("Applying tunnel settings failed: \(err.localizedDescription)")
                completionHandler(err)
                return
            }

            // An IPv6 default route is only useful when the path can carry v6
            // *and* something can resolve over it; otherwise every AAAA lookup
            // and Happy Eyeballs attempt black-holes into the tunnel.
            ipv6Enabled = pathSupportsIPv6 && dnsServers.contains { IPv6Address($0) != nil }
        }

        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

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
            "Applying tunnel settings ipv4_enabled=true ipv6_enabled=\(ipv6Enabled) dns_servers=[\(dnsServers.joined(separator: ","))] mtu=1400"
        )
        recordProviderEvent(category: "settings", message: "apply_start ipv6=\(ipv6Enabled)", flightEvent: .tunnelConnected)

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    /// Whether a resolver address is reachable from the flow data plane.
    ///
    /// Flow mode terminates connections inside lwIP and re-originates them
    /// from the physical interface, so a server-supplied resolver only works
    /// if it is globally routable. Private, loopback, link-local and
    /// unique-local addresses name hosts on the *server's* network: following
    /// them either black-holes (the observed failure — UDP flows accumulating
    /// with nothing ever resolving) or, worse, reaches a same-numbered host on
    /// the user's own LAN.
    private static func isFlowReachableResolver(_ address: String) -> Bool {
        if let v4 = IPv4Address(address) {
            let b = [UInt8](v4.rawValue)
            guard b.count == 4 else { return false }
            switch (b[0], b[1]) {
            case (0, _), (127, _), (255, _): return false  // unspecified, loopback, broadcast
            case (10, _):                    return false  // 10/8
            case (169, 254):                 return false  // link-local
            case (192, 168):                 return false  // 192.168/16
            case (172, 16...31):             return false  // 172.16/12
            default:                         return true
            }
        }
        if let v6 = IPv6Address(address) {
            let b = [UInt8](v6.rawValue)
            guard b.count == 16 else { return false }
            if b.allSatisfy({ $0 == 0 }) { return false }                    // ::
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }  // ::1
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return false }        // fe80::/10
            if (b[0] & 0xFE) == 0xFC { return false }                        // fc00::/7
            return true
        }
        return false
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

    private func handleIncomingPacketBatchFromServer(_ batch: InboundPacketBatch, generation: Int) {
        guard generation == currentWebSocketGeneration(), shouldHandlePackets(),
              !batch.packets.isEmpty else { return }
        // The batch is delivered synchronously on the native WebSocket reader
        // thread, which has no runloop and therefore no autorelease-pool drain.
        // Wrap the writePackets bridging so the [Data]->NSArray<NSData*>
        // temporaries — each retaining a zero-copy native packet lease — are
        // released per batch instead of accumulating for the whole session.
        autoreleasepool {
            // Split mode: this is where DNS answers come back, and therefore
            // the only place domain -> IP can be learned for classification.
            // Read-only, so the packets still go to the OS untouched.
            if let flowBridge {
                for packet in batch.packets {
                    packet.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        flowBridge.observeInboundPacket(
                            base.assumingMemoryBound(to: UInt8.self),
                            length: raw.count
                        )
                    }
                }
            }

            let bytes = batch.packets.reduce(into: Int64.zero) { $0 += Int64($1.count) }
            let accepted = packetFlow.writePackets(batch.packets, withProtocols: batch.protocols)
            recordPacketFlowWrite(
                packetCount: Int64(batch.packets.count),
                byteCount: bytes,
                accepted: accepted
            )
        }
    }

    private func shouldContinueReadLoop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isReadLoopActive
    }

    private func shouldReadOutboundPackets() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        // In split mode the packet-flow adapter owns ingress and feeds the
        // classifier, which decides per flow whether a packet goes to lwIP or
        // to the websocket. Running this loop as well would read the same
        // packets into the transport unclassified.
        if configuration?.dataPlaneMode == .split {
            return false
        }
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
            recordProviderEvent(category: "invariant", message: "violation \(invariant)", flightEvent: .invariantViolation)
            #if FPTN_SIGNPOSTS
            signpostLock.lock(); TunnelSignposts.invariantViolation(); signpostLock.unlock()
            #endif
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

        // Detach the split plane from the outgoing bridge before it is stopped
        // or released. The native setter blocks until no ingress call is still
        // inside the old pointer, so doing it here is what keeps it from
        // dangling across a reconnect. lwIP keeps running throughout: only the
        // transport changes, so live direct flows survive.
        if previousClient != nil {
            updateSplitTransport(nil)
        }

        // PR3A: begin NativeTeardown after detach.
        #if FPTN_SIGNPOSTS
        var teardownSP: (id: OSSignpostID, state: OSSignpostIntervalState)?
        if previousClient != nil {
            signpostLock.lock()
            let sp = TunnelSignposts.beginNativeTeardown(generation: generation)
            teardownSP = sp
            signpostLock.unlock()
        }
        #endif

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

            // Fold this generation's exact native admission count into the
            // session total exactly once. This is the only place a
            // generation's upload bytes are finalized — see
            // exactSessionUploadBytes(), which adds the *live* generation's
            // current count on top of this accumulator.
            diagnosticsLock.lock()
            if generation != lastFinalizedUploadGeneration {
                completedGenerationUploadBytes += finalStatus.outboundAdmissionCopyBytes
                lastFinalizedUploadGeneration = generation
            }
            diagnosticsLock.unlock()

            if finalStatus.activeOperations != 0 || !finalStatus.stopCleanupCompleted {
                logInvariantOnce(.incompleteNativeTeardown)
            }
            if finalStatus.liveClients > 1 {
                logInvariantOnce(.multipleNativeClients)
            }

            // PR3A: end NativeTeardown + BridgeLifetime after final status.
            #if FPTN_SIGNPOSTS
            signpostLock.lock()
            if let sp = teardownSP {
                TunnelSignposts.endNativeTeardown(sp.state, generation: generation, activeOps: finalStatus.activeOperations)
            }
            if let bsp = bridgeSignpost {
                TunnelSignposts.endBridgeLifetime(bsp.state, generation: bsp.generation)
                bridgeSignpost = nil
            }
            signpostLock.unlock()
            #endif
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

        // PR3A: begin BridgeLifetime for the newly exposed bridge.
        #if FPTN_SIGNPOSTS
        if newClient != nil {
            signpostLock.lock()
            let sp = TunnelSignposts.beginBridgeLifetime(generation: generation)
            bridgeSignpost = (generation: generation, id: sp.0, state: sp.1)
            signpostLock.unlock()
        }
        #endif

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
        recordProviderEvent(category: "packet_flow", message: "read_backpressure reason=\(reason) delay=\(String(format: "%.2f", clampedDelay))s", flightEvent: .queueHighWater)
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

    private func recordPacketFlowWrite(
        packetCount writtenPacketCount: Int64,
        byteCount: Int64,
        accepted: Bool
    ) {
        let now = Date()
        var previousInboundActivityAt: Date?

        stateLock.lock()
        previousInboundActivityAt = counters.lastInboundActivityAt
        counters.transportReceivedPackets += writtenPacketCount
        counters.transportReceivedBytes += byteCount
        if accepted {
            counters.packetFlowWritePackets += writtenPacketCount
        }
        if accepted {
            counters.packetFlowWriteBytes += byteCount
        }
        counters.lastInboundActivityAt = now
        stateLock.unlock()

        logActivityResumedIfNeeded(
            direction: "inbound",
            previousActivityAt: previousInboundActivityAt,
            now: now,
            packetCount: writtenPacketCount,
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
        endReconnectDelaySignpost()
    }

    // PR3A: signpost helpers — capture state under lock, emit outside.
    #if FPTN_SIGNPOSTS
    private func endReconnectDelaySignpost() {
        signpostLock.lock()
        let sp = reconnectSignpost
        reconnectSignpost = nil
        signpostLock.unlock()
        if let sp {
            TunnelSignposts.endReconnectDelay(sp.state, attempt: sp.attempt)
        }
    }

    private func endStartupSignpost() {
        signpostLock.lock()
        let sp = startupSignpost
        startupSignpost = nil
        signpostLock.unlock()
        if let sp {
            TunnelSignposts.endTunnelStartup(sp)
        }
    }
    #endif

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

    private let pathClassifier = NetworkPathEpisodeClassifier(scope: .tunnel)
    private var pendingPathOutageWorkItem: DispatchWorkItem?

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

        let obs = NetworkPathObservation(
            satisfied: isSatisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
        let (effect, scope) = pathClassifier.handleUpdate(obs, now: ContinuousClock().now)
        switch effect {
        case .transitionRecorded(let observation):
            pendingPathOutageWorkItem?.cancel()
            pendingPathOutageWorkItem = nil
            logger.info("Network path satisfied=\(observation.satisfied) network=\(pathSummary) [scope=\(scope.rawValue)\(self.currentDiagnosticContext().formatted())]")
        case .scheduleConfirmation(let episodeID, _):
            pendingPathOutageWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let (timerEffect, timerScope) = self.pathClassifier.evaluateConfirmationTimer(episodeID: episodeID, now: ContinuousClock().now)
                if timerEffect == .confirmedOutage(episodeID: episodeID) {
                    logger.warning("Default network path remained unsatisfied after 2.0s [scope=\(timerScope.rawValue) classification=confirmedOutage\(self.currentDiagnosticContext().formatted())]")
                }
            }
            pendingPathOutageWorkItem = item
            eventQueue.asyncAfter(deadline: .now() + .seconds(2), execute: item)
        case .recovered(let classification, let duration):
            pendingPathOutageWorkItem?.cancel()
            pendingPathOutageWorkItem = nil
            let durMs = Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            logger.info("Default network path recovered after \(durMs)ms [scope=\(scope.rawValue) classification=\(classification.rawValue)\(self.currentDiagnosticContext().formatted())]")
        case .duplicateIgnored, .cancelConfirmation, .confirmedOutage:
            break
        }

        recordProviderEvent(category: "path", message: "path_satisfied=\(isSatisfied) network=\(pathSummary)", pathSatisfied: isSatisfied, flightEvent: .pathChanged)
        updateDiagnosticsHeartbeat(lastEvent: "path_satisfied=\(isSatisfied) network=\(pathSummary)")
        if didPathChange {
            #if FPTN_SIGNPOSTS
            TunnelSignposts.networkPathChanged(satisfied: isSatisfied)
            #endif
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
            recordProviderEvent(category: "reconnect", message: "skip_path_recovery_not_reconnectable attempt=\(attempt)", reconnectAttempt: attempt, flightEvent: .reconnectScheduled)
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
            pathSatisfied: true,
            flightEvent: .reconnectScheduled
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

        telemetryTickCount = 0
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        let interval = Int(rateSampleIntervalSeconds)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.handleTelemetryTick()
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

    /// Fires every `rateSampleIntervalSeconds` (1s) on eventQueue. Peak
    /// bandwidth is sampled every tick so short bursts aren't averaged away;
    /// the heavier durable snapshot write + memory-pressure evaluation stay on
    /// the coarser `telemetryIntervalSeconds` (15s) cadence.
    private func handleTelemetryTick() {
        telemetryTickCount &+= 1
        let ticksPerDurableWrite = max(1, UInt64(telemetryIntervalSeconds / rateSampleIntervalSeconds))
        let isDurableTick = telemetryTickCount % ticksPerDurableWrite == 0

        #if FPTN_MEASUREMENT_BUILD
        // PR-1 (Measurement Safety): sample only Mach memory counters, and
        // only on the coarse cadence — no per-second work during profiling.
        guard isDurableTick else { return }
        let memory = TunnelMemoryPressureSnapshot(
            residentBytes: residentMemoryBytes(),
            physFootprintBytes: physFootprintBytes()
        )
        evaluateMemoryPressure(memory: memory)
        #else
        updateTrafficRateTracking()
        guard isDurableTick else { return }
        let snapshot = currentSnapshot()
        let memory = TunnelMemoryPressureSnapshot(
            residentBytes: snapshot.memoryResidentBytes,
            physFootprintBytes: snapshot.memoryPhysFootprintBytes
        )
        writeLifecycleSnapshot()
        evaluateMemoryPressure(memory: memory)
        logFlowCounters()
        #endif
    }

    /// The flow data plane produces no other telemetry: the websocket counters
    /// stay at zero because it never opens one, so these adapter totals are the
    /// only window into whether packets reach lwIP and come back. Absence of
    /// this line means the l3Tunnel path is running.
    private func logFlowCounters() {
        guard let adapter = flowAdapter else { return }
        let mode = configuration?.dataPlaneMode.rawValue ?? "unknown"

        // The routing funnel, in decision order. `dns_parsed=0` means no DNS
        // answer was ever observed, so nothing can be attributed to a domain
        // and every flow necessarily falls to the default (fptn) verdict —
        // which looks exactly like split routing being broken.
        if mode == "split", let flowBridge {
            let s = flowBridge.splitCounters()
            logger.info(
                """
                Split funnel batches=\(s.batches) \
                to_stack=\(s.packetsToStack) to_transport=\(s.packetsToTransport) \
                dropped=\(s.packetsDropped) rollbacks=\(s.rollbacks) \
                decisions=\(s.decisions) hits=\(s.tableHits) \
                unclassifiable=\(s.unclassifiable) flows=\(s.activeFlows) \
                dns_parsed=\(s.dnsResponsesParsed) dns_recorded=\(s.dnsMappingsRecorded) \
                dns_entries=\(s.dnsEntries) router_unknown=\(s.routerUnknownFlows)
                """
            )
        }

        // Funnel, in pipeline order. Whichever stage stops advancing is where
        // packets are being lost; see FlowCounters in flow_counters.h.
        let c = flowBridge?.flowCounters() ?? FPTNFlowCounters()
        logger.info(
            """
            Flow funnel mode=\(mode) started=\(self.flowBridge?.isStarted ?? false) \
            ne_read=\(adapter.totalReadPackets)/\(adapter.totalReadBytes)B \
            lwip_in=\(c.inputPackets)/\(c.inputBytes)B \
            zerocopy=\(c.ingressZeroCopyPackets) copy=\(c.ingressCopyPackets) dropped=\(c.droppedPackets) \
            tcp_flows=\(c.activeTcpFlows)/\(c.peakTcpFlows) udp_flows=\(c.activeUdpFlows)/\(c.peakUdpFlows) \
            outbound_tcp=\(c.tcpOutboundActive)/\(c.tcpOutboundOpenedTotal) outbound_udp=\(c.udpOutboundActive) \
            lwip_out=\(c.outputPackets)/\(c.outputBytes)B \
            ne_write=\(adapter.totalWritePackets)/\(adapter.totalWriteBytes)B
            """
        )

        // Pressure and memory on their own line: these are what precede a
        // jetsam kill, and they are the reason a speed test can end the
        // extension while every funnel stage still looks healthy.
        let footprintMB = String(format: "%.1f", Double(physFootprintBytes() ?? 0) / 1_048_576)
        let residentMB = String(format: "%.1f", Double(residentMemoryBytes() ?? 0) / 1_048_576)
        logger.info(
            """
            Flow pressure backpressure=\(c.tcpBackpressureEvents) tcp_resets=\(c.tcpResets) \
            udp_drops=\(c.udpDrops) lease_exhaustions=\(c.leasePoolExhaustions) \
            stale_reads=\(adapter.staleReadCallbacks) \
            footprint=\(footprintMB)MB resident=\(residentMB)MB
            """
        )
    }

    /// Exact session upload total, computed on demand — never cached or
    /// accumulated from periodic deltas (that would lose bytes at reconnect
    /// boundaries). `completedGenerationUploadBytes` only ever gains a
    /// generation's bytes once (see replaceWebSocketClient); this adds the
    /// live generation's current count on top, querying wsClient directly
    /// rather than the currentSnapshot()/writeLifecycleSnapshot() pattern of
    /// falling back to lastNativeStatus — that fallback intentionally keeps
    /// reporting a torn-down generation's last-known status for diagnostic
    /// display, which would double-count here.
    private func exactSessionUploadBytes() -> UInt64 {
        stateLock.lock()
        let client = wsClient
        stateLock.unlock()
        let liveGenerationBytes = client?.status.outboundAdmissionCopyBytes ?? 0

        diagnosticsLock.lock()
        let completed = completedGenerationUploadBytes
        diagnosticsLock.unlock()

        return completed + liveGenerationBytes
    }

    /// Samples the exact session totals against the previous 15s tick to
    /// track peak bandwidth. Uses mach_continuous_time() rather than Date()
    /// so a wall-clock adjustment (NTP, timezone/DST) can't corrupt the
    /// rate. The dispatch timer isn't a strict 15.000s cadence (it can drift
    /// or be coalesced), hence "nominal" window in the wire type.
    private func updateTrafficRateTracking() {
        let currentUpload = exactSessionUploadBytes()
        stateLock.lock()
        // Download = bytes received from the server this session, regardless of
        // local packet-flow backpressure. transportReceivedBytes is the honest
        // "downloaded" figure; packetFlowWriteBytes would undercount whenever a
        // writePackets() is rejected downstream.
        let currentDownload = counters.transportReceivedBytes
        stateLock.unlock()
        let now = mach_continuous_time()

        diagnosticsLock.lock()
        if previousRateSampleMachTime != 0 {
            let elapsedSeconds = Self.machTicksToSeconds(now - previousRateSampleMachTime)
            if elapsedSeconds > 0 {
                let uploadDelta = currentUpload >= previousSessionUploadBytes
                    ? currentUpload - previousSessionUploadBytes : 0
                let downloadDelta = currentDownload >= previousSessionDownloadBytes
                    ? UInt64(currentDownload - previousSessionDownloadBytes) : 0
                peakUploadBytesPerSecond = max(peakUploadBytesPerSecond, UInt64(Double(uploadDelta) / elapsedSeconds))
                peakDownloadBytesPerSecond = max(peakDownloadBytesPerSecond, UInt64(Double(downloadDelta) / elapsedSeconds))
            }
        }
        previousSessionUploadBytes = currentUpload
        previousSessionDownloadBytes = currentDownload
        previousRateSampleMachTime = now
        diagnosticsLock.unlock()
    }

    private static func machTicksToSeconds(_ ticks: UInt64) -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
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
            recordProviderEvent(category: "state", message: "\(previousState.rawValue)->\(state.rawValue) reason=\(reason)", runtimeState: state.rawValue, flightEvent: .tunnelConnected)
        }
        if previousReasserting != newReasserting {
            logger.info("Tunnel reasserting=\(newReasserting)")
            recordProviderEvent(category: "state", message: "reasserting=\(newReasserting)", runtimeState: state.rawValue, flightEvent: .tunnelConnected)
        }
        updateDiagnosticsHeartbeat(lastEvent: "state=\(state.rawValue)")
    }

    private func finishStart(with error: Error?) {
        #if FPTN_SIGNPOSTS
        signpostLock.lock()
        if let sp = startupSignpost {
            TunnelSignposts.endTunnelStartup(sp)
            startupSignpost = nil
        }
        signpostLock.unlock()
        #endif
        var completion: ((Error?) -> Void)?

        stateLock.lock()
        completion = startCompletion
        startCompletion = nil
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        stateLock.unlock()

        recordProviderEvent(category: "startup", message: "finishStart error=\(error?.localizedDescription ?? "none")", flightEvent: .tunnelStopped)
        updateDiagnosticsHeartbeat(lastEvent: "finishStart")
        completion?(error)
    }

    private func currentSnapshot() -> TunnelRuntimeSnapshot {
        // PR2: copy Swift fields and bridge reference under lock,
        // then query native status OUTSIDE the lock to avoid holding
        // stateLock during the C++ getStatus() call.
        let client: WebsocketClientBridge?
        let savedNativeStatus: WebsocketClientStatus?
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
            nativeStopCleanupCompleted: status?.stopCleanupCompleted ?? false,
            nativeOutboundAdmissionCopyBytes: status?.outboundAdmissionCopyBytes ?? 0,
            nativeLivePacketLeases: status?.livePacketLeases ?? 0,
            nativePeakPacketLeases: status?.peakPacketLeases ?? 0
        )
    }

    /// This is an IPC response for the foreground app, not diagnostics
    /// telemetry. Session totals and peak bandwidth are computed
    /// provider-side (not left for the UI to reconstruct from repeated
    /// polls) because only the provider observes traffic while the app is
    /// backgrounded — see exactSessionUploadBytes()/updateTrafficRateTracking().
    private func currentTrafficSnapshot() -> TunnelTrafficSnapshotV1 {
        stateLock.lock()
        // Download = received-from-server (see updateTrafficRateTracking).
        let downloadBytes = max(0, counters.transportReceivedBytes)
        stateLock.unlock()

        let uploadBytes = exactSessionUploadBytes()

        diagnosticsLock.lock()
        let peakUpload = peakUploadBytesPerSecond
        let peakDownload = peakDownloadBytesPerSecond
        diagnosticsLock.unlock()

        return TunnelTrafficSnapshotV1(
            sessionUploadBytes: uploadBytes,
            sessionDownloadBytes: UInt64(downloadBytes),
            peakUploadBytesPerSecond: peakUpload,
            peakDownloadBytesPerSecond: peakDownload,
            peakBandwidthNominalWindowSeconds: UInt32(rateSampleIntervalSeconds),
            sessionStartMonotonicTime: tunnelStartedMachTime,
            sampleMonotonicTime: mach_continuous_time()
        )
    }

    /// The full live status returned to the app on the 1 Hz `getStatus` poll.
    /// Folds `currentTrafficSnapshot()` together with memory, outbound-queue,
    /// packet-lease and session-identity counters — the same values the durable
    /// binary snapshot carries — so the foreground Telemetry screen is driven
    /// by this live feed rather than the coarse 15s snapshot. See
    /// TunnelStatusSnapshotV1.
    private func currentStatusSnapshot() -> TunnelStatusSnapshotV1 {
        let traffic = currentTrafficSnapshot()

        stateLock.lock()
        let client = wsClient
        let savedNativeStatus = lastNativeStatus
        let generation = websocketGeneration
        let reconnAttempt = reconnectAttempt
        let sessionToken = tunnelSessionToken
        stateLock.unlock()

        // Query native status outside stateLock; fall back to Mach counters.
        let status = client?.status ?? savedNativeStatus
        let footprint = status?.memoryPhysFootprintBytes ?? physFootprintBytes() ?? 0
        let resident = status?.memoryResidentBytes ?? residentMemoryBytes() ?? 0

        diagnosticsLock.lock()
        if footprint > physicalFootprintPeakBytes {
            physicalFootprintPeakBytes = footprint
        }
        let peakFootprint = physicalFootprintPeakBytes
        diagnosticsLock.unlock()

        return TunnelStatusSnapshotV1(
            traffic: traffic,
            memoryFootprintBytes: footprint,
            memoryResidentBytes: resident,
            memoryFootprintPeakBytes: peakFootprint,
            outboundQueuedBytes: status?.queuedBytes ?? 0,
            outboundQueuedBytesPeak: status?.queuedBytesPeak ?? 0,
            queueFullCount: status?.queueFullCount ?? 0,
            livePacketLeases: status?.livePacketLeases ?? 0,
            peakPacketLeases: status?.peakPacketLeases ?? 0,
            nativeActiveOperations: status?.activeOperations ?? 0,
            sessionToken: sessionToken,
            websocketGeneration: UInt32(generation),
            reconnectAttempt: UInt32(max(0, reconnAttempt))
        )
    }

    // PR-1 (Measurement Safety): @autoclosure prevents the interpolated
    // message string from being constructed in Measurement builds.
    // The #if gate eliminates the entire call (including category string
    // literals) at compile time rather than relying on a runtime guard
    // inside TunnelDiagnosticsStore.
    // PR3: binary-only event recording. No JSONL, no string evaluation.
    // flightEvent is mandatory — explicit numeric codes are the contract.
    // PR4b: value0/value1/value2 carry event-specific numeric payloads.
    // flags bit 0 = wasConnected (transportDisconnected), pathSatisfied (reconnect).
    private func recordProviderEvent(
        category: String,
        message: @autoclosure () -> String,
        runtimeState: String? = nil,
        generation: Int? = nil,
        reconnectAttempt: Int? = nil,
        pathSatisfied: Bool? = nil,
        flightEvent: TunnelFlightEventCode,
        flightFlags: UInt16 = 0,
        value0: UInt64 = 0,
        value1: UInt64 = 0,
        value2: UInt64 = 0
    ) {
        if let seq = flightRecorder?.recordForSession(
            flightEvent,
            sessionToken: tunnelSessionToken,
            generation: UInt32(generation ?? 0),
            flags: flightFlags,
            value0: value0,
            value1: value1,
            value2: value2
        ), seq > 0 {
            diagnosticsLock.lock()
            latestEventSequence = seq
            diagnosticsLock.unlock()
        }
    }

    private static func sessionToken(for episodeID: UUID) -> UInt64 {
        withUnsafeBytes(of: episodeID.uuid) { bytes in
            bytes.prefix(8).reduce(0) { partial, byte in
                (partial << 8) | UInt64(byte)
            }
        }
    }

    // PR3: binary-only lifecycle snapshot. No JSONL heartbeat.
    // The @autoclosure lastEvent is never evaluated.
    private func updateDiagnosticsHeartbeat(lastEvent: @autoclosure () -> String) {
        writeLifecycleSnapshot()
    }

    private func writeLifecycleSnapshot(synchronize: Bool = false) {
        let generation: Int
        let pathSatisfied: Bool
        let currentState: TunnelRuntimeState
        let reconnAttempt: Int
        let stopInitiator: LocalStopInitiator?
        let isShutdown: Bool
        let readLoopActive: Bool
        let readPending: Bool
        let stopReasonRaw: Int?
        let client: WebsocketClientBridge?
        let savedNativeStatus: WebsocketClientStatus?
        let downloadBytes: Int64

        stateLock.lock()
        generation = websocketGeneration
        pathSatisfied = isNetworkPathSatisfied
        currentState = runtimeState
        reconnAttempt = reconnectAttempt
        stopInitiator = localStopInitiator
        isShutdown = shutdownRequested
        readLoopActive = isReadLoopActive
        readPending = isPacketReadPending
        stopReasonRaw = lastStopReasonRawValue
        client = wsClient
        savedNativeStatus = lastNativeStatus
        // Download = received-from-server (see updateTrafficRateTracking).
        downloadBytes = counters.transportReceivedBytes
        stateLock.unlock()

        // Query native status outside stateLock.
        let liveStatus = client?.status
        let status = liveStatus ?? savedNativeStatus
        let identity = ProviderProcessIdentity.shared

        let footprint = status?.memoryPhysFootprintBytes ?? physFootprintBytes() ?? 0
        let resident = status?.memoryResidentBytes ?? residentMemoryBytes() ?? 0

        // exactSessionUploadBytes() locks stateLock/diagnosticsLock itself —
        // must be called outside both, never nested inside them.
        let uploadBytes = exactSessionUploadBytes()

        // Protect peak + sequence under diagnosticsLock.
        diagnosticsLock.lock()
        if footprint > physicalFootprintPeakBytes {
            physicalFootprintPeakBytes = footprint
        }
        let peakBytes = physicalFootprintPeakBytes
        let eventSeq = latestEventSequence
        let peakUpload = peakUploadBytesPerSecond
        let peakDownload = peakDownloadBytesPerSecond
        diagnosticsLock.unlock()

        let hasBridge = client != nil

        var flags: UInt32 = 0
        if isShutdown { flags |= TunnelSnapshotFlag.shutdownRequested.rawValue }
        if currentState == .reasserting || currentState == .waitingForNetwork {
            flags |= TunnelSnapshotFlag.reasserting.rawValue
        }
        if pathSatisfied { flags |= TunnelSnapshotFlag.pathSatisfied.rawValue }
        if readLoopActive { flags |= TunnelSnapshotFlag.readLoopActive.rawValue }
        if readPending { flags |= TunnelSnapshotFlag.packetReadPending.rawValue }
        if status?.stopCleanupCompleted == true { flags |= TunnelSnapshotFlag.nativeStopCleanupCompleted.rawValue }

        let wroteSnapshot = lifecycleStore?.write(
            pid: UInt32(identity.pid),
            processToken: identity.processToken,
            processSequence: identity.processSequence,
            processStartedMachTime: identity.startedMachTime,
            tunnelSessionToken: tunnelSessionToken,
            tunnelStartedMachTime: tunnelStartedMachTime,
            providerStopReason: UInt32(stopReasonRaw ?? 0),
            localStopInitiator: stopInitiator?.binaryCode ?? 0,
            nativeDisconnectCode: status?.disconnectCode.rawValue ?? 0,
            nativeStopOrigin: status?.stopOrigin.rawValue ?? 0,
            flags: flags,
            lifecycleState: currentState.binaryCode,
            websocketGeneration: UInt32(generation),
            reconnectAttempt: UInt32(reconnAttempt),
            physicalFootprintBytes: footprint,
            physicalFootprintPeakBytes: peakBytes,
            residentBytes: resident,
            activeBridges: hasBridge ? 1 : 0,
            activeNativeClients: UInt32(status?.liveClients ?? 0),
            nativeActiveOperations: status?.activeOperations ?? 0,
            activeReaderCoroutines: UInt32(status?.activeReaderCoroutines ?? 0),
            activeSenderCoroutines: UInt32(status?.activeSenderCoroutines ?? 0),
            activeReadLoops: readLoopActive ? 1 : 0,
            outboundQueuedBytes: status?.queuedBytes ?? 0,
            outboundQueuedBytesPeak: status?.queuedBytesPeak ?? 0,
            latestEventSequence: eventSeq,
            sessionAcceptedUploadBytes: uploadBytes,
            sessionAcceptedDownloadBytes: UInt64(max(0, downloadBytes)),
            peakUploadBytesPerSecond: peakUpload,
            peakDownloadBytesPerSecond: peakDownload,
            queueFullCount: status?.queueFullCount ?? 0,
            livePacketLeases: status?.livePacketLeases ?? 0,
            peakPacketLeases: status?.peakPacketLeases ?? 0,
            peakBandwidthNominalWindowSeconds: UInt32(rateSampleIntervalSeconds),
            synchronize: synchronize
        ) ?? true

        if !wroteSnapshot {
            recordProviderEvent(
                category: "diagnostics",
                message: "lifecycle snapshot write failed",
                flightEvent: .snapshotWriteFailed
            )
        }
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
            lastRecordedMemoryLevel = .normal
            return
        case .warning, .emergency:
            // PR4b: record binary event on level change, independent
            // of OSLog throttling. warning→emergency is always recorded.
            if memory.level != lastRecordedMemoryLevel {
                lastRecordedMemoryLevel = memory.level
                let eventCode: TunnelFlightEventCode = memory.level == .emergency ? .memoryCritical : .memoryWarning
                diagnosticsLock.lock()
                let peak = physicalFootprintPeakBytes
                diagnosticsLock.unlock()
                recordProviderEvent(
                    category: "memory",
                    message: "memory_pressure \(memory.description)",
                    flightEvent: eventCode,
                    value0: memory.physFootprintBytes ?? 0,
                    value1: memory.residentBytes ?? 0,
                    value2: peak
                )
            }

            // OSLog throttled separately.
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
            #if FPTN_SIGNPOSTS
            signpostLock.lock(); TunnelSignposts.memoryWarning(); signpostLock.unlock()
            #endif
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

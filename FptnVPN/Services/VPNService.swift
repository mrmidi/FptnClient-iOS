/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine
import Darwin
import CryptoKit
@preconcurrency import NetworkExtension
import FptnSharedCore
import FptnSharedTunnel
import FptnServerSelection
import FptnConnectionOrchestration
import FptnNativeBootstrap

/// The provider's live tunnel status plus when the app received it, so the
/// Telemetry screen can tell "fresh" from "the provider went quiet." Distinct
/// from `VPNConnection`, which stays a lean UI model for the Home screen.
struct LiveTunnelStatus: Sendable {
    let snapshot: TunnelStatusSnapshotV1
    let receivedAt: Date
}

/// One tick per traffic poll that produced a usable rate — the Telemetry
/// chart's sample source.
///
/// Deliberately a separate publisher from `connection`. `VPNConnection` is a
/// struct behind `@Published`, so *every* mutation of it republishes — the
/// status observer, an error string, a server change. A chart driven off
/// `$connection` records a bandwidth sample for each of those, inventing
/// samples that correspond to no measurement. This fires exactly once per
/// completed poll.
struct TrafficTick: Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    /// Width of the window the rate was measured over. Shorter than the
    /// nominal window right after a gap, while it refills.
    let windowSeconds: TimeInterval
    let receivedAt: Date
}

@MainActor
final class VPNService: ObservableObject {
    @Published var connection = VPNConnection()
    /// Live provider status from the 1 Hz `getStatus` poll (memory, queue,
    /// packet leases, session identity). `nil` while disconnected or before the
    /// first successful poll — the Telemetry screen falls back to the durable
    /// binary snapshot then.
    @Published private(set) var liveStatus: LiveTunnelStatus?
    /// Bandwidth samples for the Telemetry chart. See `TrafficTick` for why
    /// this isn't folded into `connection`.
    @Published private(set) var trafficTick: TrafficTick?

    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?
    private var isDisconnectRequested: Bool = true
    private var activeCoordinator: (any ConnectionLifecycleCoordinating)?
    private var activeEpisodeID: ConnectionEpisodeID?
    private var connectionTask: Task<Void, Never>?
    private var trafficPollingTask: Task<Void, Never>?
    /// Rolling window of cumulative-counter readings backing the displayed
    /// rate. Holds the samples covering `rateWindowSeconds`, plus the one
    /// immediately older so the window stays fully spanned.
    private var trafficWindow: [TrafficSample] = []
    private var lastTrafficPollingFailureAt: Date?

    /// The rate shown to the user is measured across this window, not between
    /// consecutive polls. The provider reports exact cumulative byte counters,
    /// so `(bytes_now − bytes_then) / elapsed` is exact over *any* span — a
    /// 1-second diff is equally exact but describes an instant, and chunked
    /// media traffic is genuinely on/off at that resolution: it reads zero in
    /// every gap between chunk fetches. Five seconds spans those gaps without
    /// lagging a real stall.
    private let rateWindowSeconds: TimeInterval = 5
    private var connectionGeneration: UInt64 = 0
    private var ipcRequestIDCounter: UInt64 = 0
    private let requestFailureClassifier = ProviderRequestFailureClassifier()

    private let tokenService = TokenService.shared
    private let healthStore = VPNService.makeHealthStore()

    // MARK: - Public

    func syncWithSystem() {
        Task { @MainActor in
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                guard let manager = managers.first else {
                    packetTunnelProvider = nil
                    clearConnectionState()
                    return
                }

                packetTunnelProvider = manager
                observeTunnelStatus(manager)
                await syncTunnelStatus()
            } catch {
                logger.warning("syncWithSystem: failed to load preferences: \(error.localizedDescription)")
            }
        }
    }

    func connect() {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            isDisconnectRequested = false
            await performConnect(generation: generation)
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        isDisconnectRequested = true
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = .stopping
        stopTrafficPolling(clearHistory: false)

        Task {
            if let activeCoordinator {
                await activeCoordinator.disconnect(reason: .userInitiated)
            } else {
                await stopObservedTunnel(initiator: .user, reason: .userRequested)
            }
        }
    }

    static func pushLogLevelToActiveTunnel(_ level: LogLevel) async {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers?.first,
              let session = manager.connection as? NETunnelProviderSession,
              [.connected, .connecting, .reasserting].contains(manager.connection.status) else {
            return
        }

        let sharedLogLevel = SharedLogLevel(rawValue: level.rawValue)
        let msg = TunnelControlMessage(action: .setLogLevel, logLevel: sharedLogLevel)
        if let data = try? JSONEncoder().encode(msg) {
            try? session.sendProviderMessage(data)
        }
    }

    func refreshCachedServerWarning() {
        // No-op
    }

    func formatConnectionTime() -> String {
        return connection.connectionDurationString
    }

    func formatSpeed(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB/s", mb)
    }

    // MARK: - Private Connect Flow

    private func performConnect(generation: UInt64) async {
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

        guard isCurrent(generation) else { return }

        guard let tokenData = await tokenService.getTokenData() else {
            connection.errorMessage = "No token data available"
            logger.error("No token data available")
            return
        }

        guard isCurrent(generation) else { return }

        let servers = await tokenService.getServers()
        guard !servers.isEmpty else {
            connection.errorMessage = "No servers available"
            logger.warning("No servers available")
            return
        }

        let settings = SettingsService.shared
        let bootstrapContext = BootstrapContext(
            networkClass: .wifi,
            sni: settings.sni,
            censorshipStrategy: FptnSharedCore.CensorshipStrategy(storedValue: settings.censorshipStrategy.rawValue),
            ipv6Available: false,
            tokenConfigurationID: configurationID(tokenUsername: tokenData.username, servers: servers)
        )
        let credentials = Credentials(username: tokenData.username, password: tokenData.password)
        let runtimeOptions = tunnelRuntimeOptions(settings: settings)
        let recoveryPolicy: TunnelRecoveryPolicy = settings.reconnectEnabled
            ? .automatic(AutoTunnelRecoveryPolicy(
                sameServerAttempts: settings.maxReconnectAttempts,
                reconnectDelaySeconds: settings.reconnectDelay
            ))
            : .none

        let bootstrapper = NativeServerBootstrapper { server, context in
            iOSNativeBootstrapClient(server: server, context: context)
        }
        let tunnelController = NETunnelController()

        let result: ConnectionStartResult

        switch connection.connectionMode {
        case .manual(let chosenServer):
            connection.selectedServer = chosenServer
            let deps = ManualConnectionDependencies(
                bootstrapper: bootstrapper,
                tunnelController: tunnelController
            )
            let coordinator = makeManualCoordinator(deps: deps)
            activeCoordinator = coordinator
            let request = ManualConnectionRequest(
                server: chosenServer,
                credentials: credentials,
                bootstrapContext: bootstrapContext,
                tunnelRecoveryPolicy: recoveryPolicy,
                tunnelRuntimeOptions: runtimeOptions
            )
            result = await coordinator.connect(request)

        case .auto:
            let selector = AutoServerSelector(
                healthStore: healthStore,
                bootstrapper: bootstrapper
            )
            let deps = AutoConnectionDependencies(
                selector: selector,
                tunnelController: tunnelController
            )
            let coordinator = makeAutoCoordinator(deps: deps)
            activeCoordinator = coordinator
            let request = AutoConnectionRequest(
                servers: servers,
                credentials: credentials,
                bootstrapContext: bootstrapContext,
                tunnelRecoveryPolicy: recoveryPolicy,
                reselectionPolicy: AutoReselectionPolicy(
                    maxReplacementAttempts: max(0, settings.maxReconnectAttempts),
                    delaySeconds: settings.reconnectDelay
                ),
                tunnelRuntimeOptions: runtimeOptions
            )
            result = await coordinator.connect(request)
        }

        guard isCurrent(generation) else { return }

        switch result {
        case .started(let episodeID):
            logger.info("Connection started successfully for episode \(episodeID.rawValue.uuidString)")
            activeEpisodeID = episodeID
            connection.isConnected = false
            connection.isConnecting = true
            await adoptSystemManager()
        case .failed(let failure):
            logger.error("Connection failed: \(failure)")
            connection.errorMessage = "Connection failed: \(failure)"
            connection.isConnected = false
            connection.isConnecting = false
        case .cancelled:
            logger.info("Connection request cancelled")
            connection.isConnected = false
            connection.isConnecting = false
        }
    }

    // MARK: - Status observation

    private let statusTransitionTracker = TunnelStatusTransitionTracker()

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
                guard let self, let conn = self.packetTunnelProvider?.connection else { return }
                await self.handleTunnelStatusUpdate(conn.status, source: .notification)
            }
        }
    }

    private func syncTunnelStatus() async {
        guard let tunnelConnection = packetTunnelProvider?.connection else {
            clearConnectionState()
            return
        }
        await handleTunnelStatusUpdate(tunnelConnection.status, source: .initialSync)
    }

    private func handleTunnelStatusUpdate(_ status: NEVPNStatus, source: TunnelStatusObservationSource) async {
        guard let tunnelConnection = packetTunnelProvider?.connection else {
            clearConnectionState()
            return
        }

        let systemStatus = status.diagnosticStatus
        if let event = statusTransitionTracker.observe(systemStatus, source: source) {
            let epContext = activeEpisodeID.map { " [episode=\($0.rawValue.uuidString.prefix(8))]" } ?? ""
            logger.info("\(event.formattedMessage)\(epContext)")
        }

        switch status {
        case .connected:
            let isNewSession = connection.connectedAt == nil
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = false
            if isNewSession {
                connection.connectedAt = tunnelConnection.connectedDate ?? Date()
                stopTrafficPolling(clearHistory: true)
            }
            startTrafficPollingIfNeeded()
            if let activeEpisodeID {
                await activeCoordinator?.handle(.tunnelConnected(activeEpisodeID))
            }
        case .reasserting:
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = true
            connection.runtimeState = .reasserting
            stopTrafficPolling(clearHistory: false)
        case .connecting:
            connection.isConnected = false
            connection.isConnecting = true
            connection.isReconnecting = false
            connection.runtimeState = .starting
            stopTrafficPolling(clearHistory: false)
        case .disconnecting:
            connection.isConnected = false
            connection.isConnecting = false
            connection.isReconnecting = false
            connection.runtimeState = .stopping
            stopTrafficPolling(clearHistory: false)
        case .disconnected, .invalid:
            if !isDisconnectRequested, let activeEpisodeID {
                await activeCoordinator?.handle(.tunnelDisconnected(activeEpisodeID, .remoteClosed))
            }
            activeEpisodeID = nil
            clearConnectionState()
        @unknown default:
            break
        }
    }

    private func clearConnectionState() {
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = nil
        connection.connectedAt = nil
        stopTrafficPolling(clearHistory: false)
    }

    // MARK: - Live transfer statistics

    private func startTrafficPollingIfNeeded() {
        guard trafficPollingTask == nil else { return }

        trafficPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTrafficSnapshot()

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func stopTrafficPolling(clearHistory: Bool) {
        trafficPollingTask?.cancel()
        trafficPollingTask = nil
        trafficWindow.removeAll()
        liveStatus = nil
        trafficTick = nil
        var next = connection
        next.downloadSpeed = 0
        next.uploadSpeed = 0
        if clearHistory {
            next.speedHistory = []
        }
        connection = next
    }

    private func refreshTrafficSnapshot() async {
        guard connection.isConnected,
              !connection.isReconnecting,
              !isDisconnectRequested,
              let manager = packetTunnelProvider,
              manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            return
        }

        ipcRequestIDCounter &+= 1
        let requestID = ipcRequestIDCounter
        let t0 = ContinuousClock().now
        let statusAtSend = manager.connection.status.diagnosticStatus
        let reqContext = ProviderRequestContext(
            requestID: requestID,
            action: .getStatus,
            episodeID: activeEpisodeID?.rawValue,
            appConnectAttemptID: nil,
            statusAtSend: statusAtSend,
            disconnectRequestedAtSend: isDisconnectRequested,
            startedAt: t0
        )

        do {
            let status = try await Self.sendProviderMessage(
                TunnelControlMessage(action: .getStatus),
                via: session,
                expecting: TunnelStatusSnapshotV1.self
            )
            guard !Task.isCancelled, connection.isConnected, !connection.isReconnecting else {
                return
            }
            applyStatusSnapshot(status, sampledAt: Date())
        } catch {
            let statusAtComp = (packetTunnelProvider?.connection.status ?? .invalid).diagnosticStatus
            let t1 = ContinuousClock().now
            let completion = ProviderRequestCompletion(
                statusAtCompletion: statusAtComp,
                currentEpisodeID: activeEpisodeID?.rawValue,
                result: .missingResponse,
                completedAt: t1
            )
            if let classification = requestFailureClassifier.classify(context: reqContext, completion: completion) {
                switch classification {
                case .expectedShutdownRace, .staleResponse:
                    logger.debug("Provider request failed [reqID=\(requestID) action=getStatus statusAtSend=\(statusAtSend) statusAtCompletion=\(statusAtComp)]: classification=\(classification.rawValue)")
                case .stopIntentNotAcknowledged, .unexpectedNoResponse, .malformedProviderReply:
                    logger.warning("Provider request failed [reqID=\(requestID) action=getStatus statusAtSend=\(statusAtSend) statusAtCompletion=\(statusAtComp)]: classification=\(classification.rawValue)")
                }
            }
        }
    }

    private func applyStatusSnapshot(
        _ status: TunnelStatusSnapshotV1,
        sampledAt: Date
    ) {
        // Publish the full live status for the Telemetry screen (memory, queue,
        // leases, identity). The Home screen keeps consuming the lean
        // VPNConnection fields below.
        liveStatus = LiveTunnelStatus(snapshot: status, receivedAt: sampledAt)

        let snapshot = status.traffic
        let current = TrafficSample(snapshot: snapshot, timestamp: sampledAt)
        appendToTrafficWindow(current)
        let rate = currentWindowedRate()

        // ONE mutation, so ONE @Published emission. Assigning the ten fields
        // individually publishes `connection` ten times per poll: subscribers
        // see eight of those carrying the *previous* poll's speeds (they're
        // emitted before downloadSpeed is assigned), and anything sampling the
        // stream per emission — the Telemetry chart did — records ten points
        // per second with identical timestamps.
        var next = connection
        // Exact, provider-reported values — no diffing needed, unlike the rate.
        next.sessionUploadBytes = snapshot.sessionUploadBytes
        next.sessionDownloadBytes = snapshot.sessionDownloadBytes
        next.peakUploadBytesPerSecond = snapshot.peakUploadBytesPerSecond
        next.peakDownloadBytesPerSecond = snapshot.peakDownloadBytesPerSecond
        next.peakBandwidthNominalWindowSeconds = snapshot.peakBandwidthNominalWindowSeconds
        next.trafficMetricsSampledAt = snapshot.sampleMonotonicTime
        next.trafficMetricsAvailable = true

        if let rate {
            next.downloadSpeed = rate.downloadBytesPerSecond
            next.uploadSpeed = rate.uploadBytesPerSecond
            next.speedHistory.append(
                SpeedSample(
                    timestamp: sampledAt,
                    downloadMbps: rate.downloadBytesPerSecond * 8 / 1_000_000,
                    uploadMbps: rate.uploadBytesPerSecond * 8 / 1_000_000
                )
            )
            if next.speedHistory.count > 300 {
                next.speedHistory.removeFirst(next.speedHistory.count - 300)
            }
        }
        connection = next

        // Only once the window can actually produce a rate; a single reading
        // is not a measurement, and charting it as zero would be a fabrication.
        guard let rate else { return }
        trafficTick = TrafficTick(
            downloadMbps: rate.downloadBytesPerSecond * 8 / 1_000_000,
            uploadMbps: rate.uploadBytesPerSecond * 8 / 1_000_000,
            windowSeconds: rate.windowSeconds,
            receivedAt: sampledAt
        )
    }

    private func appendToTrafficWindow(_ current: TrafficSample) {
        if let newest = trafficWindow.last {
            // Counters going backwards means the provider began a fresh
            // session. A gap longer than the window means polling stopped
            // (the app was backgrounded and suspended) — spanning it would
            // report the gap's *average* as the current rate. Both cases
            // invalidate the window rather than the newest reading.
            let wentBackwards = current.uploadBytes < newest.uploadBytes
                || current.downloadBytes < newest.downloadBytes
            let pollingStalled = current.timestamp.timeIntervalSince(newest.timestamp) > rateWindowSeconds
            if wentBackwards || pollingStalled {
                trafficWindow.removeAll(keepingCapacity: true)
            }
        }
        trafficWindow.append(current)

        // Retain one sample older than the cutoff so the window spans the full
        // `rateWindowSeconds` rather than however much happens to fall inside it.
        let cutoff = current.timestamp.addingTimeInterval(-rateWindowSeconds)
        if let firstInside = trafficWindow.firstIndex(where: { $0.timestamp >= cutoff }), firstInside > 1 {
            trafficWindow.removeFirst(firstInside - 1)
        }
    }

    /// Exact rate across the retained window. Returns nil until two readings
    /// exist — after a reconnect or a foreground return the window rebuilds
    /// over the following seconds, reporting honest rates over a shorter span
    /// meanwhile rather than a placeholder zero.
    private func currentWindowedRate() -> WindowedRate? {
        guard let oldest = trafficWindow.first,
              let newest = trafficWindow.last,
              trafficWindow.count >= 2 else { return nil }

        let elapsed = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard elapsed > 0 else { return nil }

        // Monotonicity is enforced on append, so these can't underflow; the
        // saturating form keeps that true if the invariant ever moves.
        let downloadBytes = newest.downloadBytes >= oldest.downloadBytes
            ? newest.downloadBytes - oldest.downloadBytes : 0
        let uploadBytes = newest.uploadBytes >= oldest.uploadBytes
            ? newest.uploadBytes - oldest.uploadBytes : 0

        return WindowedRate(
            downloadBytesPerSecond: Double(downloadBytes) / elapsed,
            uploadBytesPerSecond: Double(uploadBytes) / elapsed,
            windowSeconds: elapsed
        )
    }

    private func logTrafficPollingFailureIfNeeded(_ error: Error) {
        let now = Date()
        guard lastTrafficPollingFailureAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
            return
        }
        lastTrafficPollingFailureAt = now
        logger.debug("Tunnel traffic snapshot unavailable: \(error.localizedDescription)")
    }

    nonisolated private static func sendProviderMessage<Response: Decodable & Sendable>(
        _ message: TunnelControlMessage,
        via session: NETunnelProviderSession,
        expecting responseType: Response.Type
    ) async throws -> Response {
        let payload = try JSONEncoder().encode(message)

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { responseData in
                    guard let responseData else {
                        continuation.resume(throwing: TunnelIPCError.missingResponse)
                        return
                    }

                    do {
                        continuation.resume(returning: try JSONDecoder().decode(responseType, from: responseData))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private struct WindowedRate {
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
        let windowSeconds: TimeInterval
    }

    private struct TrafficSample {
        let uploadBytes: UInt64
        let downloadBytes: UInt64
        let timestamp: Date

        init(snapshot: TunnelTrafficSnapshotV1, timestamp: Date) {
            self.uploadBytes = snapshot.sessionUploadBytes
            self.downloadBytes = snapshot.sessionDownloadBytes
            self.timestamp = timestamp
        }
    }

    private enum TunnelIPCError: LocalizedError {
        case missingResponse

        var errorDescription: String? {
            switch self {
            case .missingResponse:
                return "Tunnel did not return a response"
            }
        }
    }

    /// Handles an orphaned provider after an app relaunch. Normal disconnects are
    /// routed through the episode-owning coordinator above.
    private func stopObservedTunnel(initiator: DisconnectInitiator, reason: FptnSharedTunnel.DisconnectReason) async {
        logger.info("stopObservedTunnel initiator=\(initiator.rawValue) reason=\(reason.rawValue)")
        let manager: NETunnelProviderManager?
        if let packetTunnelProvider {
            manager = packetTunnelProvider
        } else {
            manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        }
        guard let manager else { return }

        if let session = manager.connection as? NETunnelProviderSession {
            let message = TunnelControlMessage(action: .prepareStop, initiator: .appDisconnect)
            if let data = try? JSONEncoder().encode(message) {
                try? session.sendProviderMessage(data)
            }
        }
        manager.connection.stopVPNTunnel()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    private func adoptSystemManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else { return }
            packetTunnelProvider = manager
            observeTunnelStatus(manager)
            await syncTunnelStatus()
        } catch {
            logger.warning("Unable to observe newly started tunnel: \(error.localizedDescription)")
        }
    }

    private func tunnelRuntimeOptions(settings: SettingsService) -> TunnelRuntimeOptions {
        let perAppMode: PerAppTunnelMode = switch AppFilterService.shared.mode {
        case .off: .disabled
        case .onlyAllowed: .allowSelected
        case .exceptDisallowed: .excludeSelected
        }
        return TunnelRuntimeOptions(
            logLevel: SharedLogLevel(rawValue: settings.logLevel.rawValue) ?? .warning,
            websocketIdleTimeoutSeconds: settings.websocketIdleTimeoutSeconds,
            customDnsIPv4: settings.customDnsEnabled ? settings.customDnsIPv4 : nil,
            perAppMode: perAppMode,
            allowedBundleIDs: AppFilterService.shared.selectedBundleIDs
        )
    }

    private func configurationID(tokenUsername: String, servers: [VPNServer]) -> String {
        let canonicalServers = servers
            .map { "\($0.host):\($0.port):\($0.md5Fingerprint):\($0.name)" }
            .sorted()
            .joined(separator: "|")
        let material = "\(tokenUsername)|\(canonicalServers)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeHealthStore() -> FileBackedServerHealthStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FptnVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileBackedServerHealthStore(fileURL: directory.appendingPathComponent("server-health.json"))
    }
}

extension NEVPNStatus {
    var diagnosticStatus: TunnelSystemStatus {
        switch self {
        case .invalid: .invalid
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reasserting: .reasserting
        case .disconnecting: .disconnecting
        @unknown default: .unknown
        }
    }

    var diagnosticName: String {
        diagnosticStatus.description
    }
}


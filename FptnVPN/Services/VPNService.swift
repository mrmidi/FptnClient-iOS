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

@MainActor
final class VPNService: ObservableObject {
    @Published var connection = VPNConnection()
    /// Live provider status from the 1 Hz `getStatus` poll (memory, queue,
    /// packet leases, session identity). `nil` while disconnected or before the
    /// first successful poll — the Telemetry screen falls back to the durable
    /// binary snapshot then.
    @Published private(set) var liveStatus: LiveTunnelStatus?

    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?
    private var isUserInitiatedDisconnect: Bool = true
    private var activeCoordinator: (any ConnectionLifecycleCoordinating)?
    private var activeEpisodeID: ConnectionEpisodeID?
    private var connectionTask: Task<Void, Never>?
    private var trafficPollingTask: Task<Void, Never>?
    private var previousTrafficSample: TrafficSample?
    private var lastTrafficPollingFailureAt: Date?
    private var connectionGeneration: UInt64 = 0

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
            isUserInitiatedDisconnect = false
            await performConnect(generation: generation)
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        isUserInitiatedDisconnect = true
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = .stopping
        stopTrafficPolling(clearHistory: false)

        Task {
            if let activeCoordinator {
                await activeCoordinator.disconnect(reason: .userInitiated)
            } else {
                await stopObservedTunnel()
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
            if !isUserInitiatedDisconnect, let activeEpisodeID {
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
        previousTrafficSample = nil
        liveStatus = nil
        connection.downloadSpeed = 0
        connection.uploadSpeed = 0
        if clearHistory {
            connection.speedHistory = []
        }
    }

    private func refreshTrafficSnapshot() async {
        guard connection.isConnected,
              !connection.isReconnecting,
              let manager = packetTunnelProvider,
              manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            return
        }

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
            logTrafficPollingFailureIfNeeded(error)
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
        // Exact, provider-reported values — no diffing needed, unlike the
        // current-speed calc below which still needs two samples.
        connection.sessionUploadBytes = snapshot.sessionUploadBytes
        connection.sessionDownloadBytes = snapshot.sessionDownloadBytes
        connection.peakUploadBytesPerSecond = snapshot.peakUploadBytesPerSecond
        connection.peakDownloadBytesPerSecond = snapshot.peakDownloadBytesPerSecond
        connection.peakBandwidthNominalWindowSeconds = snapshot.peakBandwidthNominalWindowSeconds
        connection.trafficMetricsSampledAt = snapshot.sampleMonotonicTime
        connection.trafficMetricsAvailable = true

        let current = TrafficSample(snapshot: snapshot, timestamp: sampledAt)
        guard let previous = previousTrafficSample else {
            previousTrafficSample = current
            return
        }

        guard current.uploadBytes >= previous.uploadBytes,
              current.downloadBytes >= previous.downloadBytes else {
            // The provider has started a fresh session; establish a new
            // baseline rather than presenting an invalid negative rate.
            previousTrafficSample = current
            return
        }

        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return }

        let uploadBytes = current.uploadBytes - previous.uploadBytes
        let downloadBytes = current.downloadBytes - previous.downloadBytes
        connection.uploadSpeed = Double(uploadBytes) / elapsed
        connection.downloadSpeed = Double(downloadBytes) / elapsed
        connection.speedHistory.append(
            SpeedSample(
                timestamp: current.timestamp,
                downloadMbps: connection.downloadSpeed * 8 / 1_000_000,
                uploadMbps: connection.uploadSpeed * 8 / 1_000_000
            )
        )
        if connection.speedHistory.count > 300 {
            connection.speedHistory.removeFirst(connection.speedHistory.count - 300)
        }
        previousTrafficSample = current
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
    private func stopObservedTunnel() async {
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


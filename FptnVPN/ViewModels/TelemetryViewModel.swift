/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import SwiftUI
import Combine
import FptnSharedTunnel

/// Drives the Telemetry screen from real data. Ownership is split:
///
/// - `VPNService.$connection` (already polling `.getStatus` at 1 Hz while
///   connected) is the *live* source for current speed and connection
///   identity/state. It does not carry session totals/peaks yet — that
///   lands once the provider-side exact-totals work (Track 3) is wired in;
///   until then those fields simply stay `nil`.
/// - The durable binary lifecycle snapshot (`TunnelDiagnosticsDecoder`) is
///   read only on view-open, on foreground, and on a coarse ~15s tick — not
///   once a second — for memory and queue/lease health, which the live IPC
///   struct deliberately doesn't carry.
/// - Chart samples are foreground-gated and segmented: losing the live
///   source (backgrounding) starts a new segment, and the first sample after
///   regaining it establishes a fresh baseline without being charted, since
///   it would otherwise average over the whole gap.
@MainActor
final class TelemetryViewModel: ObservableObject {
    @Published private(set) var snapshot = TelemetrySnapshot()
    @Published private(set) var memorySamples: [MemorySample] = []
    @Published private(set) var bandwidthSamples: [BandwidthSample] = []
    @Published private(set) var events: [TelemetryEvent] = []
    @Published var selectedWindow: TelemetryTimeWindow = .fiveMinutes
    @Published var isHealthExpanded = false
    @Published var isNetworkExpanded = false

    private weak var vpnService: VPNService?
    private let decoder = TunnelDiagnosticsDecoder.production

    private var cancellables = Set<AnyCancellable>()
    private var diagnosticsTimer: Timer?

    private var isForeground = true
    private var currentSegmentID: UInt64 = 0
    private var isAwaitingFreshBaselineAfterGap = false
    private var lastConsumedSnapshotSequence: UInt64?
    private var currentSessionToken: UInt64?
    private var lastMemorySampleAt: Date?

    private let maximumBandwidthSamples = 3_600  // 1/sec, ~1 hour
    private let maximumMemorySamples = 720        // ~5s cadence, ~1 hour
    /// Memory now arrives at 1 Hz on the live feed; chart it at most this often
    /// so the buffer still spans ~an hour and the line stays readable.
    private let memorySampleMinInterval: TimeInterval = 5
    /// How long the last live `getStatus` reply stays "fresh." Past this, the
    /// provider has gone quiet on the 1 Hz poll and the screen falls back to the
    /// durable binary snapshot and flips the availability pill to Stale.
    private let liveStatusStaleThreshold: TimeInterval = 3

    init(vpnService: VPNService) {
        self.vpnService = vpnService
    }

    func start() {
        guard cancellables.isEmpty else { return }
        memorySamples = []
        bandwidthSamples = []
        events = []
        currentSegmentID = 0
        isAwaitingFreshBaselineAfterGap = false
        lastConsumedSnapshotSequence = nil
        lastMemorySampleAt = nil

        vpnService?.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] connection in
                self?.handleConnectionUpdate(connection)
            }
            .store(in: &cancellables)

        vpnService?.$liveStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.handleLiveStatus(status)
            }
            .store(in: &cancellables)

        refreshFromLifecycleSnapshot()
        refreshEvents()

        // The live feed (1 Hz) drives the screen while foregrounded; this coarse
        // timer only backstops the durable fallback, the flight-recorder events,
        // and the staleness pill when the provider goes silent between polls.
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAvailability()
                self?.refreshFromLifecycleSnapshot()
                self?.refreshEvents()
            }
        }
    }

    func stop() {
        cancellables.removeAll()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    /// Forwarded from `TelemetryView`'s `\.scenePhase`. Drives the paused
    /// state and the explicit chart-gap segmenting — losing or regaining the
    /// live source always starts a new segment.
    func setScenePhase(_ phase: ScenePhase) {
        let goingForeground = phase == .active
        if goingForeground != isForeground {
            beginNewSegment()
        }
        isForeground = goingForeground
        snapshot.availability = currentAvailability(for: vpnService?.connection)
        if goingForeground {
            refreshFromLifecycleSnapshot()
            refreshEvents()
        }
    }

    func filteredMemorySamples() -> [MemorySample] {
        guard let duration = selectedWindow.duration else { return memorySamples }
        let cutoff = Date().addingTimeInterval(-duration)
        return memorySamples.filter { $0.timestamp >= cutoff }
    }

    func filteredBandwidthSamples() -> [BandwidthSample] {
        guard let duration = selectedWindow.duration else { return bandwidthSamples }
        let cutoff = Date().addingTimeInterval(-duration)
        return bandwidthSamples.filter { $0.timestamp >= cutoff }
    }

    // MARK: - Live connection updates (already-real 1 Hz poll via VPNService)

    private func handleConnectionUpdate(_ connection: VPNConnection) {
        let now = Date()

        var next = snapshot
        next.connectionState = Self.mapConnectionState(connection)
        next.serverName = connection.selectedServer?.name
        next.connectedDuration = connection.connectedAt.map { now.timeIntervalSince($0) } ?? 0
        next.downloadMbps = connection.downloadSpeed * 8 / 1_000_000
        next.uploadMbps = connection.uploadSpeed * 8 / 1_000_000
        if connection.trafficMetricsAvailable {
            next.sessionUploadBytes = connection.sessionUploadBytes
            next.sessionDownloadBytes = connection.sessionDownloadBytes
            next.uploadPeakMbps = Double(connection.peakUploadBytesPerSecond) * 8 / 1_000_000
            next.downloadPeakMbps = Double(connection.peakDownloadBytesPerSecond) * 8 / 1_000_000
        }
        next.thermalState = Self.mapThermalState(ProcessInfo.processInfo.thermalState)
        next.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.availability = currentAvailability(for: connection)
        next.lastUpdated = now
        snapshot = next

        guard isForeground, connection.isConnected else { return }
        if isAwaitingFreshBaselineAfterGap {
            // Reflects the whole gap, not current bandwidth — establishes a
            // fresh baseline but isn't charted.
            isAwaitingFreshBaselineAfterGap = false
            return
        }
        bandwidthSamples.append(BandwidthSample(
            timestamp: now,
            downloadMbps: next.downloadMbps,
            uploadMbps: next.uploadMbps,
            segmentID: currentSegmentID
        ))
        trimBandwidthSamples()
    }

    private func currentAvailability(for connection: VPNConnection?) -> TelemetryAvailability {
        guard isForeground else { return .paused }
        guard let connection else { return .unavailable }
        if connection.runtimeState == .stopping { return .providerStopping }
        if connection.isReconnecting || connection.isWaitingForNetwork {
            return .stale(secondsAgo: liveStatusAgeSeconds() ?? 0)
        }
        if connection.isConnected {
            // A fresh 1 Hz reply means Live. Otherwise the provider has gone
            // quiet on the poll and what's on screen is the last durable
            // snapshot, not live — say so rather than claiming "Healthy · Live"
            // right up until the extension is OOM-killed.
            if isLiveStatusFresh() { return .live }
            return .stale(secondsAgo: liveStatusAgeSeconds() ?? 0)
        }
        return .unavailable
    }

    // MARK: - Live provider status (1 Hz getStatus feed)

    /// Primary driver of memory / queue / lease / identity while foregrounded.
    /// Supersedes the durable binary snapshot, which now only backfills when
    /// this feed is absent or stale (see `refreshFromLifecycleSnapshot`).
    private func handleLiveStatus(_ live: LiveTunnelStatus?) {
        guard let live else {
            // Feed dropped (disconnect/stop). Reflect it in the pill; the
            // memory/health values hold their last durable state.
            refreshAvailability()
            return
        }

        let s = live.snapshot
        let footprintMB = Double(s.memoryFootprintBytes) / 1_000_000

        var next = snapshot
        next.memoryPhysicalMB = footprintMB
        next.memoryResidentMB = Double(s.memoryResidentBytes) / 1_000_000
        next.memoryPeakMB = Double(s.memoryFootprintPeakBytes) / 1_000_000
        next.outboundQueueBytes = Int(s.outboundQueuedBytes)
        next.outboundQueuePeakBytes = Int(s.outboundQueuedBytesPeak)
        next.queueFullEvents = Int(s.queueFullCount)
        next.livePacketLeases = Int(s.livePacketLeases)
        next.peakPacketLeases = Int(s.peakPacketLeases)
        next.nativeOperations = Int(s.nativeActiveOperations)
        next.websocketGeneration = Int(s.websocketGeneration)
        next.reconnectAttempt = Int(s.reconnectAttempt)
        next.sessionTokenHex = Self.hex(s.sessionToken)
        next.healthLevel = Self.mapHealthLevel(footprintMB: footprintMB, queueFullCount: s.queueFullCount)
        next.availability = currentAvailability(for: vpnService?.connection)
        next.lastUpdated = live.receivedAt
        snapshot = next

        currentSessionToken = s.sessionToken
        recordMemorySampleIfNeeded(footprintMB, at: live.receivedAt)
    }

    private func isLiveStatusFresh() -> Bool {
        guard let live = vpnService?.liveStatus else { return false }
        return Date().timeIntervalSince(live.receivedAt) <= liveStatusStaleThreshold
    }

    private func liveStatusAgeSeconds() -> Int? {
        guard let live = vpnService?.liveStatus else { return nil }
        return max(0, Int(Date().timeIntervalSince(live.receivedAt)))
    }

    private func refreshAvailability() {
        snapshot.availability = currentAvailability(for: vpnService?.connection)
    }

    /// Charts memory at a coarser cadence than the 1 Hz feed so the buffer still
    /// spans ~an hour. Foreground-gated and segment-aware like the other paths.
    private func recordMemorySampleIfNeeded(_ physicalMB: Double, at timestamp: Date) {
        guard isForeground else { return }
        if let last = lastMemorySampleAt,
           timestamp.timeIntervalSince(last) < memorySampleMinInterval {
            return
        }
        lastMemorySampleAt = timestamp
        memorySamples.append(MemorySample(timestamp: timestamp, physicalMB: physicalMB, segmentID: currentSegmentID))
        trimMemorySamples()
    }

    private func beginNewSegment() {
        currentSegmentID &+= 1
        isAwaitingFreshBaselineAfterGap = true
    }

    private func trimBandwidthSamples() {
        if bandwidthSamples.count > maximumBandwidthSamples {
            bandwidthSamples.removeFirst(bandwidthSamples.count - maximumBandwidthSamples)
        }
    }

    private func trimMemorySamples() {
        if memorySamples.count > maximumMemorySamples {
            memorySamples.removeFirst(memorySamples.count - maximumMemorySamples)
        }
    }

    // MARK: - Durable lifecycle snapshot (memory + queue/lease health)

    private func refreshFromLifecycleSnapshot() {
        guard let decoder, let decoded = decoder.readLifecycleSnapshot() else { return }
        guard decoded.writeSequence != lastConsumedSnapshotSequence else { return }
        // Consume the sequence before the freshness check so a stale 15s-old
        // durable snapshot can never later clobber the fresher last-live values
        // once the live feed goes quiet.
        lastConsumedSnapshotSequence = decoded.writeSequence

        // While the live 1 Hz feed is fresh it owns memory/health/identity; the
        // durable snapshot only backfills before the first poll, on a
        // backgrounded return, or after the provider dies.
        guard !isLiveStatusFresh() else { return }
        currentSessionToken = decoded.sessionToken

        let footprintMB = Double(decoded.footprintBytes) / 1_000_000
        var next = snapshot
        next.memoryPhysicalMB = footprintMB
        next.memoryResidentMB = Double(decoded.residentBytes) / 1_000_000
        next.memoryPeakMB = Double(decoded.footprintPeakBytes) / 1_000_000
        next.outboundQueueBytes = Int(decoded.outboundQueuedBytes)
        next.outboundQueuePeakBytes = Int(decoded.outboundQueuedBytesPeak)
        next.queueFullEvents = Int(decoded.queueFullCount)
        next.livePacketLeases = Int(decoded.livePacketLeases)
        next.peakPacketLeases = Int(decoded.peakPacketLeases)
        next.nativeOperations = Int(decoded.nativeActiveOperations)
        next.websocketGeneration = Int(decoded.websocketGeneration)
        next.reconnectAttempt = Int(decoded.reconnectAttempt)
        next.sessionTokenHex = Self.hex(decoded.sessionToken)
        next.healthLevel = Self.mapHealthLevel(footprintMB: footprintMB, queueFullCount: decoded.queueFullCount)

        // Fallback for session totals/peaks: live IPC (handleConnectionUpdate)
        // is the primary source while it's available. When it isn't — the
        // provider is unreachable or hasn't answered yet — fall back to the
        // last durable values persisted here, so "last known" totals still
        // show after the provider dies rather than reading as "—" forever.
        if vpnService?.connection.trafficMetricsAvailable != true {
            next.sessionUploadBytes = decoded.sessionAcceptedUploadBytes
            next.sessionDownloadBytes = decoded.sessionAcceptedDownloadBytes
            next.uploadPeakMbps = Double(decoded.peakUploadBytesPerSecond) * 8 / 1_000_000
            next.downloadPeakMbps = Double(decoded.peakDownloadBytesPerSecond) * 8 / 1_000_000
        }
        snapshot = next

        recordMemorySampleIfNeeded(footprintMB, at: Date())
    }

    // MARK: - Recent events (sparse flight-recorder ring, filtered to this session)

    private func refreshEvents() {
        guard let decoder, let sessionToken = currentSessionToken else { return }
        let result = decoder.readFlightEvents()
        events = result.events
            .filter { $0.sessionToken == sessionToken }
            .sorted { $0.sequence < $1.sequence }
            .compactMap(Self.mapFlightEvent)
    }

    private static func mapFlightEvent(_ event: TunnelDiagnosticsDecoder.DecodedFlightEvent) -> TelemetryEvent? {
        guard let code = TunnelFlightEventCode(rawValue: event.rawEventCode) else { return nil }
        let timestamp = event.timestamp ?? Date()
        switch code {
        case .processStarted, .bridgeCreated, .bridgeStartRequested, .bridgeStopRequested,
             .bridgeTeardownCompleted, .readerStarted, .readerStopped, .senderStarted,
             .senderStopped, .memorySample, .snapshotWriteFailed:
            return nil  // internal lifecycle detail, not user-facing
        case .startTunnel:
            return TelemetryEvent(timestamp: timestamp, message: "Tunnel starting", kind: .info)
        case .tunnelConnected:
            return TelemetryEvent(timestamp: timestamp, message: "Tunnel connected", kind: .success)
        case .stopTunnelEntered:
            return TelemetryEvent(timestamp: timestamp, message: "Tunnel stopping", kind: .info)
        case .tunnelStopped:
            return TelemetryEvent(timestamp: timestamp, message: "Tunnel stopped", kind: .info)
        case .bridgeConnected:
            return TelemetryEvent(timestamp: timestamp, message: "Transport connected", kind: .success)
        case .reconnectScheduled:
            return TelemetryEvent(timestamp: timestamp, message: "Reconnect scheduled", kind: .warning)
        case .reconnectStarted:
            return TelemetryEvent(timestamp: timestamp, message: "Reconnecting", kind: .warning)
        case .transportDisconnected:
            return TelemetryEvent(timestamp: timestamp, message: "Transport disconnected", kind: .warning)
        case .pathChanged:
            return TelemetryEvent(timestamp: timestamp, message: "Network path changed", kind: .info)
        case .memoryWarning:
            return TelemetryEvent(timestamp: timestamp, message: "Memory pressure: warning", kind: .warning)
        case .memoryCritical:
            return TelemetryEvent(timestamp: timestamp, message: "Memory pressure: critical", kind: .error)
        case .queueHighWater:
            return TelemetryEvent(timestamp: timestamp, message: "Outbound queue high-water", kind: .warning)
        case .invariantViolation:
            return TelemetryEvent(timestamp: timestamp, message: "Internal invariant violation", kind: .error)
        }
    }

    // MARK: - Mapping helpers

    private static func mapConnectionState(_ connection: VPNConnection) -> TelemetryConnectionState {
        if connection.runtimeState == .stopping { return .disconnecting }
        if connection.isWaitingForNetwork { return .waitingForNetwork }
        if connection.isReconnecting { return .reconnecting }
        if connection.isConnecting { return .connecting }
        if connection.isConnected { return .connected }
        return .disconnected
    }

    private static func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    private static func mapHealthLevel(footprintMB: Double, queueFullCount: UInt64) -> HealthLevel {
        if footprintMB >= TelemetrySnapshot.memoryCriticalMB { return .critical("Memory critical") }
        if footprintMB >= TelemetrySnapshot.memoryWarningMB { return .warning("Memory warning") }
        if queueFullCount > 0 { return .attention("Queue pressure") }
        return .healthy
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

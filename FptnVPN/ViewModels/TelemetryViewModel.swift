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
    @Published private(set) var displayMemorySamples: [MemorySample] = []
    @Published private(set) var displayBandwidthSamples: [BandwidthSample] = []
    @Published private(set) var events: [TelemetryEvent] = []
    @Published var selectedWindow: TelemetryTimeWindow = .fiveMinutes {
        didSet {
            guard oldValue != selectedWindow else { return }
            updateDisplaySamples()
        }
    }
    @Published var isHealthExpanded = false
    @Published var isNetworkExpanded = false
    @Published var isSplitRoutingExpanded = false

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
    private let maxChartDisplayPoints = 120       // Cap rendered marks per chart
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
        displayMemorySamples = []
        displayBandwidthSamples = []
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

        vpnService?.$trafficTick
            .receive(on: RunLoop.main)
            .sink { [weak self] tick in
                self?.handleTrafficTick(tick)
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
        displayMemorySamples
    }

    func filteredBandwidthSamples() -> [BandwidthSample] {
        displayBandwidthSamples
    }

    private func updateDisplaySamples() {
        updateDisplayMemorySamples()
        updateDisplayBandwidthSamples()
    }

    private func updateDisplayMemorySamples() {
        let rawFiltered: [MemorySample]
        if let duration = selectedWindow.duration {
            let cutoff = Date().addingTimeInterval(-duration)
            rawFiltered = memorySamples.filter { $0.timestamp >= cutoff }
        } else {
            rawFiltered = memorySamples
        }
        // Peak-preserving rather than min/max: memory moves smoothly, so an
        // envelope would only add visual noise, but the chart's whole job is
        // catching an approach to the extension's memory ceiling — so when a
        // bucket must collapse, it collapses to its highest reading.
        displayMemorySamples = bucketed(rawFiltered, maxPoints: maxChartDisplayPoints) { bucket in
            bucket.max { $0.physicalMB < $1.physicalMB }.map { [$0] } ?? []
        }
    }

    private func updateDisplayBandwidthSamples() {
        let rawFiltered: [BandwidthSample]
        if let duration = selectedWindow.duration {
            let cutoff = Date().addingTimeInterval(-duration)
            rawFiltered = bandwidthSamples.filter { $0.timestamp >= cutoff }
        } else {
            rawFiltered = bandwidthSamples
        }
        // Min/max envelope: tunnel traffic is on/off, so a bucket's lowest and
        // highest readings are both real and both meaningful. Each bucket
        // yields up to two points, hence the halved budget.
        displayBandwidthSamples = bucketed(rawFiltered, maxPoints: maxChartDisplayPoints / 2) { bucket in
            guard let low = bucket.min(by: { $0.downloadMbps < $1.downloadMbps }),
                  let high = bucket.max(by: { $0.downloadMbps < $1.downloadMbps }) else { return [] }
            // Whole samples, never synthesized pairs — so the upload value
            // plotted at a given instant is the one actually measured there.
            if low.id == high.id { return [low] }
            return low.timestamp <= high.timestamp ? [low, high] : [high, low]
        }
    }

    /// Splits samples into equal-width *time* buckets and lets `reduce` choose
    /// which real samples represent each one.
    ///
    /// Replaces index decimation (keep every Nth sample), which is only
    /// faithful for smoothly-varying data: on bursty traffic it keeps whatever
    /// happened to land on the stride and silently drops the peaks between,
    /// so the rendered shape depends on sample alignment rather than on what
    /// was measured. Bucketing by time also makes the x-axis honest when the
    /// sample rate isn't uniform.
    private func bucketed<T: TimestampedSample>(
        _ samples: [T],
        maxPoints: Int,
        reduce: ([T]) -> [T]
    ) -> [T] {
        guard samples.count > maxPoints, maxPoints >= 2,
              let first = samples.first, let last = samples.last else { return samples }

        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else { return samples }

        let bucketCount = maxPoints
        let bucketWidth = span / Double(bucketCount)
        var buckets: [[T]] = Array(repeating: [], count: bucketCount)
        for sample in samples {
            let offset = sample.timestamp.timeIntervalSince(first.timestamp)
            let index = min(bucketCount - 1, max(0, Int(offset / bucketWidth)))
            buckets[index].append(sample)
        }

        var result = buckets.flatMap { $0.isEmpty ? [] : reduce($0) }
        // The newest sample anchors the chart's endpoint marker, so it must
        // survive the reduction even when its bucket elected something else.
        if let newest = samples.last, result.last?.id != newest.id {
            result.append(newest)
        }
        return result
    }

    // MARK: - Live connection updates (already-real 1 Hz poll via VPNService)

    /// Identity, state and the exact provider-reported totals. Chart samples
    /// deliberately do NOT come from here — see `handleTrafficTick`.
    private func handleConnectionUpdate(_ connection: VPNConnection) {
        let now = Date()

        var next = snapshot
        next.connectionState = Self.mapConnectionState(connection)
        next.serverName = connection.selectedServer?.name
        next.connectedDuration = connection.connectedAt.map { now.timeIntervalSince($0) } ?? 0

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

        // Displayed as-is. `VPNService` already measures this across a rolling
        // window of exact cumulative counters, so there is nothing left to
        // smooth here — the trailing average this used to apply was measuring
        // its own publisher's fan-out, not time.
        next.downloadMbps = connection.downloadSpeed * 8 / 1_000_000
        next.uploadMbps = connection.uploadSpeed * 8 / 1_000_000
        snapshot = next
    }

    /// The chart's only sample source: exactly one tick per completed traffic
    /// poll. Foreground-gated and segment-aware, so a backgrounded stretch
    /// breaks the line instead of being drawn as an interpolated slope.
    private func handleTrafficTick(_ tick: TrafficTick?) {
        guard let tick, isForeground else { return }

        if isAwaitingFreshBaselineAfterGap {
            // First tick after regaining the live feed. Its window may still
            // straddle the gap, so it establishes the baseline without being
            // charted.
            isAwaitingFreshBaselineAfterGap = false
            return
        }

        bandwidthSamples.append(BandwidthSample(
            timestamp: tick.receivedAt,
            downloadMbps: tick.downloadMbps,
            uploadMbps: tick.uploadMbps,
            segmentID: currentSegmentID
        ))
        trimBandwidthSamples()
        updateDisplayBandwidthSamples()
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
        next.splitRouting = s.splitRouting.map(Self.mapSplitRouting)
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
        updateDisplayMemorySamples()
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
        case .unsupportedDataPlaneMode:
            return TelemetryEvent(timestamp: timestamp, message: "Unsupported data plane mode", kind: .error)
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

    private static func mapSplitRouting(_ s: TunnelSplitRoutingSnapshotV1) -> SplitRoutingSummary {
        SplitRoutingSummary(
            geoStatus: s.geoStatus,
            directFlows: s.directFlows,
            fptnFlows: s.fptnFlows,
            rejectedFlows: s.rejectedFlows,
            droppedFlows: s.droppedFlows,
            decisions: s.decisions,
            activeFlows: s.activeFlows,
            unclassifiableFlows: s.unclassifiableFlows,
            packetsToStack: s.packetsToStack,
            packetsToTransport: s.packetsToTransport,
            packetsDropped: s.packetsDropped,
            dnsResponsesParsed: s.dnsResponsesParsed,
            dnsEntries: s.dnsEntries
        )
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

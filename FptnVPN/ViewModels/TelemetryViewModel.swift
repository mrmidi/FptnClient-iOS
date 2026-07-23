/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import Combine

/// Drives the Telemetry screen with a self-contained, plausible simulation.
///
/// This is intentionally not wired to `VPNService` / the packet-tunnel provider yet —
/// it exists so the view can be designed and demoed end-to-end. Swapping the timer-driven
/// `tick()` body for real IPC samples later should not require touching `TelemetryView`.
@MainActor
final class TelemetryViewModel: ObservableObject {
    @Published private(set) var snapshot = TelemetrySnapshot()
    @Published private(set) var memorySamples: [MemorySample] = []
    @Published private(set) var bandwidthSamples: [BandwidthSample] = []
    @Published private(set) var events: [TelemetryEvent] = []
    @Published var selectedWindow: TelemetryTimeWindow = .fiveMinutes
    @Published var isHealthExpanded = false
    @Published var isNetworkExpanded = false

    private var timer: Timer?
    private let connectedAt = Date().addingTimeInterval(-18 * 60 - 24)
    private var tick: Int = 0
    private var downloadBytesTotal: Double = 0
    private var uploadBytesTotal: Double = 0
    private var downloadRateSum: Double = 0
    private var uploadRateSum: Double = 0
    private var rateSampleCount: Double = 0

    // Correlated (random-walk) noise state so consecutive samples drift smoothly
    // instead of jittering independently every tick.
    private var memoryNoise: Double = 0
    private var downloadNoise: Double = 0
    private var uploadNoise: Double = 0

    private func stepNoise(_ value: inout Double, step: Double, limit: Double) -> Double {
        value = max(-limit, min(limit, value * 0.88 + Double.random(in: -step...step)))
        return value
    }

    func start() {
        guard timer == nil else { return }
        seedHistory()
        advance()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

    // MARK: - Simulation

    private func seedHistory() {
        let now = Date()
        var memSeed: [MemorySample] = []
        var bwSeed: [BandwidthSample] = []
        for i in stride(from: 300, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(i))
            let mem = 22.0 + 2.2 * sin(Double(i) / 24.0) + stepNoise(&memoryNoise, step: 0.12, limit: 1.1)
            memSeed.append(MemorySample(timestamp: t, physicalMB: max(14, mem)))
            let dl = 16.0 + 6.0 * sin(Double(i) / 18.0) + stepNoise(&downloadNoise, step: 0.5, limit: 3.0)
            let ul = 1.6 + 0.6 * sin(Double(i) / 30.0 + 1.2) + stepNoise(&uploadNoise, step: 0.05, limit: 0.35)
            bwSeed.append(BandwidthSample(timestamp: t, downloadMbps: max(0, dl), uploadMbps: max(0, ul)))
            downloadBytesTotal += max(0, dl) * 1_000_000 / 8
            uploadBytesTotal += max(0, ul) * 1_000_000 / 8
            downloadRateSum += max(0, dl)
            uploadRateSum += max(0, ul)
            rateSampleCount += 1
        }
        memorySamples = memSeed
        bandwidthSamples = bwSeed

        events = [
            TelemetryEvent(timestamp: now.addingTimeInterval(-9 * 60 - 33), message: "Tunnel connected", kind: .success),
            TelemetryEvent(timestamp: now.addingTimeInterval(-9 * 60 - 33), message: "Default path recovered after 184 ms", kind: .info),
            TelemetryEvent(timestamp: now.addingTimeInterval(-4 * 60 - 2), message: "Server closed WebSocket", kind: .warning),
            TelemetryEvent(timestamp: now.addingTimeInterval(-4 * 60), message: "Reconnected successfully", kind: .success)
        ]
    }

    private func advance() {
        tick += 1
        let now = Date()

        let memory = 22.0 + 2.4 * sin(Double(tick) / 24.0) + stepNoise(&memoryNoise, step: 0.12, limit: 1.1)
        let clampedMemory = max(14, memory)
        memorySamples.append(MemorySample(timestamp: now, physicalMB: clampedMemory))
        trim(&memorySamples)

        let download = max(0, 16.5 + 7.0 * sin(Double(tick) / 17.0) + stepNoise(&downloadNoise, step: 0.5, limit: 3.0))
        let upload = max(0, 1.7 + 0.7 * sin(Double(tick) / 29.0 + 1.1) + stepNoise(&uploadNoise, step: 0.05, limit: 0.35))
        bandwidthSamples.append(BandwidthSample(timestamp: now, downloadMbps: download, uploadMbps: upload))
        trim(&bandwidthSamples)

        downloadBytesTotal += download * 1_000_000 / 8
        uploadBytesTotal += upload * 1_000_000 / 8
        downloadRateSum += download
        uploadRateSum += upload
        rateSampleCount += 1

        let peakMemory = memorySamples.map(\.physicalMB).max() ?? clampedMemory
        let peakDownload = rollingPeak(bandwidthSamples.map(\.downloadMbps), window: 5)
        let peakUpload = rollingPeak(bandwidthSamples.map(\.uploadMbps), window: 5)

        var next = snapshot
        next.connectionState = .connected
        next.connectedDuration = now.timeIntervalSince(connectedAt)
        next.availability = .live
        next.lastUpdated = now
        next.memoryPhysicalMB = clampedMemory
        next.memoryResidentMB = clampedMemory - 3.8
        next.memoryPeakMB = peakMemory
        next.downloadMbps = download
        next.uploadMbps = upload
        next.downloadPeakMbps = peakDownload
        next.uploadPeakMbps = peakUpload
        next.sessionDownloadBytes = downloadBytesTotal
        next.sessionUploadBytes = uploadBytesTotal
        next.averageDownloadMbps = downloadRateSum / max(1, rateSampleCount)
        next.averageUploadMbps = uploadRateSum / max(1, rateSampleCount)
        next.thermalState = clampedMemory > TelemetrySnapshot.memoryWarningMB ? .fair : .nominal
        next.outboundQueueBytes = Int(2000 + 6000 * max(0, sin(Double(tick) / 13.0)))
        next.outboundQueuePeakBytes = max(next.outboundQueueBytes, 84_000)
        next.queueFullEvents = 0
        next.livePacketLeases = 3
        next.peakPacketLeases = 28
        next.nativeOperations = 3
        next.websocketGeneration = 3
        next.healthLevel = .healthy
        next.defaultPathAvailable = true
        next.isExpensive = false
        next.isConstrained = false
        next.ipv4Available = true
        next.ipv6Available = false
        next.reconnectAttempt = 0
        next.reconnectCount = 0

        snapshot = next
    }

    private func trim(_ samples: inout [MemorySample]) {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        if samples.count > 2000 || (samples.first?.timestamp ?? .now) < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
        }
    }

    private func trim(_ samples: inout [BandwidthSample]) {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        if samples.count > 2000 || (samples.first?.timestamp ?? .now) < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
        }
    }

    private func rollingPeak(_ values: [Double], window: Int) -> Double {
        guard !values.isEmpty else { return 0 }
        var peak = 0.0
        var i = 0
        while i < values.count {
            let end = min(i + window, values.count)
            let avg = values[i..<end].reduce(0, +) / Double(end - i)
            peak = max(peak, avg)
            i += window
        }
        return peak
    }
}

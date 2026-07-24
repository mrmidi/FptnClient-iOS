import Foundation

// PR4b: app-side decoder for binary flight recorder + lifecycle snapshot.
// Injectable paths and clocks for testability. Unknown-safe: preserves
// raw numeric codes alongside optional typed interpretations.
struct TunnelDiagnosticsDecoder: Sendable {
    let ringPath: String
    let snapshotPath: String
    let continuousTime: @Sendable () -> UInt64
    let wallTime: @Sendable () -> Date
    let ticksToSeconds: @Sendable (UInt64) -> TimeInterval

    init(
        ringPath: String,
        snapshotPath: String,
        continuousTime: @escaping @Sendable () -> UInt64 = { mach_continuous_time() },
        wallTime: @escaping @Sendable () -> Date = { Date() },
        ticksToSeconds: @escaping @Sendable (UInt64) -> TimeInterval = TunnelDiagnosticsDecoder.defaultTicksToSeconds
    ) {
        self.ringPath = ringPath
        self.snapshotPath = snapshotPath
        self.continuousTime = continuousTime
        self.wallTime = wallTime
        self.ticksToSeconds = ticksToSeconds
    }

    static func defaultTicksToSeconds(_ ticks: UInt64) -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    static var production: TunnelDiagnosticsDecoder? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.mrmidi.FptnVPN"
        ) else { return nil }
        let diagDir = container.appendingPathComponent("diagnostics", isDirectory: true)
        return TunnelDiagnosticsDecoder(
            ringPath: diagDir.appendingPathComponent("flight-ring.bin").path,
            snapshotPath: diagDir.appendingPathComponent("lifecycle-snapshot.bin").path
        )
    }

    // MARK: - Decoded types

    struct DecodedFlightEvent: Sendable {
        let sequence: UInt64
        let monotonicTime: UInt64
        let processToken: UInt64
        let sessionToken: UInt64
        let rawEventCode: UInt16
        let flags: UInt16
        let generation: UInt32
        let value0: UInt64
        let value1: UInt64
        let value2: UInt64
        let timestamp: Date?
    }

    struct DecodedSnapshot: Sendable {
        let writeSequence: UInt64
        let pid: UInt32
        let processToken: UInt64
        let processSequence: UInt64
        let processStartedMachTime: UInt64
        let sessionToken: UInt64
        let tunnelStartedMachTime: UInt64
        let lifecycleState: UInt32
        let providerStopReason: UInt32
        let localStopInitiator: UInt16
        let nativeDisconnectCode: UInt16
        let nativeStopOrigin: UInt16
        let flags: UInt32
        let websocketGeneration: UInt32
        let reconnectAttempt: UInt32
        let footprintBytes: UInt64
        let footprintPeakBytes: UInt64
        let residentBytes: UInt64
        let activeBridges: UInt32
        let activeNativeClients: UInt32
        let nativeActiveOperations: UInt32
        let activeReaderCoroutines: UInt32
        let activeSenderCoroutines: UInt32
        let activeReadLoops: UInt32
        let outboundQueuedBytes: UInt64
        let outboundQueuedBytesPeak: UInt64
        let monotonicTime: UInt64
        let wallTimeNs: UInt64
        let latestEventSequence: UInt64
        let sessionAcceptedUploadBytes: UInt64
        let sessionAcceptedDownloadBytes: UInt64
        let peakUploadBytesPerSecond: UInt64
        let peakDownloadBytesPerSecond: UInt64
        let queueFullCount: UInt64
        let livePacketLeases: UInt64
        let peakPacketLeases: UInt64
        let peakBandwidthNominalWindowSeconds: UInt32

        var isControlledStop: Bool {
            // 1 = appDisconnect, 3 = systemStop (TunnelStopInitiator)
            localStopInitiator == 1 || localStopInitiator == 3
        }
    }

    // MARK: - Reading

    func readFlightEvents() -> (status: FptnReadStatus, events: [DecodedFlightEvent]) {
        let capacity = fptn_flight_recorder_capacity()
        var events = [FptnDecodedFlightEvent](
            repeating: FptnDecodedFlightEvent(),
            count: capacity
        )
        var count: Int = 0
        let status = events.withUnsafeMutableBufferPointer { buffer in
            fptn_flight_recorder_read_valid(
                ringPath,
                buffer.baseAddress,
                capacity,
                &count
            )
        }

        guard status == FPTN_READ_OK, count > 0 else {
            return (status: status, events: [])
        }

        // Build per-process wall-time anchors from processStarted events.
        var anchors: [UInt64: (machTime: UInt64, wallDate: Date)] = [:]
        for i in 0..<count {
            if events[i].event_code == 1 {  // processStarted
                let wallNs = events[i].value_1
                if wallNs > 0 {
                    anchors[events[i].process_token] = (
                        machTime: events[i].mach_continuous_time,
                        wallDate: Date(timeIntervalSince1970: TimeInterval(wallNs) / 1_000_000_000)
                    )
                }
            }
        }

        let decoded = (0..<count).map { i in
            let e = events[i]
            var timestamp: Date? = nil
            if let anchor = anchors[e.process_token],
               e.mach_continuous_time >= anchor.machTime {
                let deltaTicks = e.mach_continuous_time - anchor.machTime
                timestamp = anchor.wallDate.addingTimeInterval(ticksToSeconds(deltaTicks))
            }
            return DecodedFlightEvent(
                sequence: e.sequence,
                monotonicTime: e.mach_continuous_time,
                processToken: e.process_token,
                sessionToken: e.tunnel_session_token,
                rawEventCode: e.event_code,
                flags: e.flags,
                generation: e.websocket_generation,
                value0: e.value_0,
                value1: e.value_1,
                value2: e.value_2,
                timestamp: timestamp
            )
        }

        return (status: status, events: decoded)
    }

    func readLifecycleSnapshot() -> DecodedSnapshot? {
        var snap = FptnDecodedLifecycleSnapshot()
        let status = fptn_lifecycle_store_read_latest(snapshotPath, &snap)
        guard status == FPTN_READ_OK else { return nil }
        return DecodedSnapshot(
            writeSequence: snap.write_sequence,
            pid: snap.pid,
            processToken: snap.process_token,
            processSequence: snap.process_sequence,
            processStartedMachTime: snap.process_started_mach_time,
            sessionToken: snap.tunnel_session_token,
            tunnelStartedMachTime: snap.tunnel_started_mach_time,
            lifecycleState: snap.lifecycle_state,
            providerStopReason: snap.provider_stop_reason,
            localStopInitiator: snap.local_stop_initiator,
            nativeDisconnectCode: snap.native_disconnect_code,
            nativeStopOrigin: snap.native_stop_origin,
            flags: snap.flags,
            websocketGeneration: snap.websocket_generation,
            reconnectAttempt: snap.reconnect_attempt,
            footprintBytes: snap.physical_footprint_bytes,
            footprintPeakBytes: snap.physical_footprint_peak_bytes,
            residentBytes: snap.resident_bytes,
            activeBridges: snap.active_bridges,
            activeNativeClients: snap.active_native_clients,
            nativeActiveOperations: snap.native_active_operations,
            activeReaderCoroutines: snap.active_reader_coroutines,
            activeSenderCoroutines: snap.active_sender_coroutines,
            activeReadLoops: snap.active_read_loops,
            outboundQueuedBytes: snap.outbound_queued_bytes,
            outboundQueuedBytesPeak: snap.outbound_queued_bytes_peak,
            monotonicTime: snap.snapshot_mach_continuous_time,
            wallTimeNs: snap.snapshot_wall_time_ns,
            latestEventSequence: snap.latest_event_sequence,
            sessionAcceptedUploadBytes: snap.session_accepted_upload_bytes,
            sessionAcceptedDownloadBytes: snap.session_accepted_download_bytes,
            peakUploadBytesPerSecond: snap.peak_upload_bytes_per_second,
            peakDownloadBytesPerSecond: snap.peak_download_bytes_per_second,
            queueFullCount: snap.queue_full_count,
            livePacketLeases: snap.live_packet_leases,
            peakPacketLeases: snap.peak_packet_leases,
            peakBandwidthNominalWindowSeconds: snap.peak_bandwidth_nominal_window_seconds
        )
    }

    // MARK: - Staleness

    func ageSeconds(of snapshot: DecodedSnapshot) -> TimeInterval? {
        let now = continuousTime()
        if now >= snapshot.monotonicTime, snapshot.monotonicTime > 0 {
            return ticksToSeconds(now - snapshot.monotonicTime)
        }
        if snapshot.wallTimeNs > 0 {
            let wallDate = Date(timeIntervalSince1970: TimeInterval(snapshot.wallTimeNs) / 1_000_000_000)
            let delta = wallTime().timeIntervalSince(wallDate)
            return max(0, delta)
        }
        return nil
    }

    // MARK: - Failure report

    func makeFailureReport(disconnectReason: String) -> String {
        var lines: [String] = ["=== Failure Report: \(disconnectReason) ==="]

        guard let snap = readLifecycleSnapshot() else {
            lines.append("Snapshot: unavailable")
            return lines.joined(separator: "\n")
        }

        let age = ageSeconds(of: snap).map { String(format: "%.0fs", $0) } ?? "unknown"
        lines.append("Snapshot: seq=\(snap.writeSequence) pid=\(snap.pid) state=\(snap.lifecycleState) age=\(age)")
        lines.append("  footprint=\(snap.footprintBytes / 1024 / 1024)MB peak=\(snap.footprintPeakBytes / 1024 / 1024)MB")
        lines.append("  stopInitiator=\(snap.localStopInitiator) disconnectCode=\(snap.nativeDisconnectCode) stopOrigin=\(snap.nativeStopOrigin)")
        lines.append("  bridges=\(snap.activeBridges) clients=\(snap.activeNativeClients) ops=\(snap.nativeActiveOperations)")

        // Filter events to the failed process/session.
        let result = readFlightEvents()
        let relevant = result.events.filter {
            $0.processToken == snap.processToken &&
            ($0.sessionToken == snap.sessionToken || $0.sessionToken == 0) &&
            !isHiddenByClearWatermark($0)
        }
        lines.append("Events (this session): \(relevant.count)")
        for event in relevant.suffix(20) {
            let ts = event.timestamp.map { "\($0)" } ?? "t=\(event.monotonicTime)"
            lines.append("  [\(event.sequence)] code=\(event.rawEventCode) gen=\(event.generation) v0=\(event.value0) v1=\(event.value1) v2=\(event.value2) \(ts)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Logical clear

    struct ClearWatermark: Codable {
        let processToken: UInt64
        let latestEventSequence: UInt64
        let snapshotWriteSequence: UInt64
    }

    private var clearWatermarkPath: String {
        (ringPath as NSString).deletingLastPathComponent + "/clear-watermark.json"
    }

    func readClearWatermark() -> ClearWatermark? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: clearWatermarkPath)) else { return nil }
        return try? JSONDecoder().decode(ClearWatermark.self, from: data)
    }

    func writeClearWatermark() {
        guard let snap = readLifecycleSnapshot() else { return }
        let watermark = ClearWatermark(
            processToken: snap.processToken,
            latestEventSequence: snap.latestEventSequence,
            snapshotWriteSequence: snap.writeSequence
        )
        guard let data = try? JSONEncoder().encode(watermark) else { return }
        try? data.write(to: URL(fileURLWithPath: clearWatermarkPath))
    }

    private func isHiddenByClearWatermark(_ event: DecodedFlightEvent) -> Bool {
        guard let wm = readClearWatermark() else { return false }
        return event.processToken == wm.processToken &&
               event.sequence <= wm.latestEventSequence
    }

    // MARK: - Export

    func exportText() -> String {
        var lines: [String] = ["=== Binary Diagnostics ==="]

        if let snap = readLifecycleSnapshot() {
            let age = ageSeconds(of: snap).map { String(format: "%.0fs", $0) } ?? "unknown"
            lines.append("Snapshot: seq=\(snap.writeSequence) pid=\(snap.pid) state=\(snap.lifecycleState) age=\(age)")
            lines.append("  footprint=\(snap.footprintBytes / 1024 / 1024)MB peak=\(snap.footprintPeakBytes / 1024 / 1024)MB resident=\(snap.residentBytes / 1024 / 1024)MB")
            lines.append("  bridges=\(snap.activeBridges) clients=\(snap.activeNativeClients) ops=\(snap.nativeActiveOperations) queued=\(snap.outboundQueuedBytes)")
            lines.append("  stopInitiator=\(snap.localStopInitiator) disconnectCode=\(snap.nativeDisconnectCode) stopOrigin=\(snap.nativeStopOrigin)")
        } else {
            lines.append("Snapshot: unavailable")
        }

        let result = readFlightEvents()
        let visible = result.events.filter { !isHiddenByClearWatermark($0) }
        lines.append("Events: \(visible.count) (status=\(result.status))")
        for event in visible.suffix(30) {
            let ts = event.timestamp.map { "\($0)" } ?? "t=\(event.monotonicTime)"
            lines.append("  [\(event.sequence)] proc=\(event.processToken) sess=\(event.sessionToken) code=\(event.rawEventCode) gen=\(event.generation) v0=\(event.value0) v1=\(event.value1) v2=\(event.value2) flags=\(event.flags) \(ts)")
        }

        return lines.joined(separator: "\n")
    }
}

import Foundation

// PR3: snapshot flags matching the C++ SnapshotFlags enum.
enum TunnelSnapshotFlag: UInt32 {
    case shutdownRequested = 1
    case reasserting = 2
    case pathSatisfied = 4
    case readLoopActive = 8
    case packetReadPending = 16
    case nativeStopCleanupCompleted = 32
    case recorderError = 64
}

// PR3: RAII Swift wrapper over the C lifecycle snapshot store.
final class TunnelLifecycleSnapshotStore: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    init?(path: String) {
        guard let h = path.withCString({ fptn_lifecycle_store_create($0) }) else {
            return nil
        }
        handle = h
    }

    deinit {
        fptn_lifecycle_store_destroy(handle)
    }

    func write(
        pid: UInt32,
        processToken: UInt64,
        processSequence: UInt64,
        processStartedMachTime: UInt64,
        tunnelSessionToken: UInt64,
        tunnelStartedMachTime: UInt64,
        providerStopReason: UInt32 = 0,
        localStopInitiator: UInt16 = 0,
        nativeDisconnectCode: UInt16 = 0,
        nativeStopOrigin: UInt16 = 0,
        flags: UInt32 = 0,
        lifecycleState: UInt32 = 0,
        websocketGeneration: UInt32 = 0,
        reconnectAttempt: UInt32 = 0,
        physicalFootprintBytes: UInt64 = 0,
        physicalFootprintPeakBytes: UInt64 = 0,
        residentBytes: UInt64 = 0,
        activeBridges: UInt32 = 0,
        activeNativeClients: UInt32 = 0,
        nativeActiveOperations: UInt32 = 0,
        activeReaderCoroutines: UInt32 = 0,
        activeSenderCoroutines: UInt32 = 0,
        activeReadLoops: UInt32 = 0,
        outboundQueuedBytes: UInt64 = 0,
        outboundQueuedBytesPeak: UInt64 = 0,
        latestEventSequence: UInt64 = 0,
        sessionAcceptedUploadBytes: UInt64 = 0,
        sessionAcceptedDownloadBytes: UInt64 = 0,
        peakUploadBytesPerSecond: UInt64 = 0,
        peakDownloadBytesPerSecond: UInt64 = 0,
        queueFullCount: UInt64 = 0,
        livePacketLeases: UInt64 = 0,
        peakPacketLeases: UInt64 = 0,
        peakBandwidthNominalWindowSeconds: UInt32 = 0,
        synchronize: Bool = false
    ) -> Bool {
        fptn_lifecycle_store_write(
            handle,
            pid, processToken, processSequence, processStartedMachTime,
            tunnelSessionToken, tunnelStartedMachTime,
            providerStopReason, localStopInitiator,
            nativeDisconnectCode, nativeStopOrigin,
            mach_continuous_time(),
            UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
            flags, lifecycleState, websocketGeneration, reconnectAttempt,
            physicalFootprintBytes, physicalFootprintPeakBytes, residentBytes,
            activeBridges, activeNativeClients, nativeActiveOperations,
            activeReaderCoroutines, activeSenderCoroutines, activeReadLoops,
            outboundQueuedBytes, outboundQueuedBytesPeak, latestEventSequence,
            sessionAcceptedUploadBytes, sessionAcceptedDownloadBytes,
            peakUploadBytesPerSecond, peakDownloadBytesPerSecond,
            queueFullCount, livePacketLeases, peakPacketLeases,
            peakBandwidthNominalWindowSeconds,
            synchronize ? 1 : 0
        ) != 0
    }
}

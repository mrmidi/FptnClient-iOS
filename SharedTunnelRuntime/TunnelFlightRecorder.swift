import Foundation

// PR3: process-lifetime identity. Created once per provider process.
final class ProviderProcessIdentity: @unchecked Sendable {
    static let shared = ProviderProcessIdentity()

    let pid: UInt64
    let processToken: UInt64
    let startedMachTime: UInt64
    let processSequence: UInt64

    private init() {
        pid = UInt64(getpid())
        processToken = Self.secureRandomUInt64()
        startedMachTime = mach_continuous_time()
        processSequence = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private static func secureRandomUInt64() -> UInt64 {
        var value: UInt64 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &value)
        return value
    }
}

// PR3: flight event codes matching the C++ EventCode enum.
enum TunnelFlightEventCode: UInt16, Sendable {
    case processStarted = 1
    case startTunnel = 2
    case tunnelConnected = 3
    case stopTunnelEntered = 4
    case tunnelStopped = 5
    case bridgeCreated = 6
    case bridgeStartRequested = 7
    case bridgeConnected = 8
    case bridgeStopRequested = 9
    case bridgeTeardownCompleted = 10
    case readerStarted = 11
    case readerStopped = 12
    case senderStarted = 13
    case senderStopped = 14
    case reconnectScheduled = 15
    case reconnectStarted = 16
    case transportDisconnected = 17
    case pathChanged = 18
    case memorySample = 19
    case memoryWarning = 20
    case memoryCritical = 21
    case queueHighWater = 22
    case invariantViolation = 23
    case snapshotWriteFailed = 24
    case unsupportedDataPlaneMode = 25
}

// PR3: RAII Swift wrapper over the C flight recorder.
// Allocation-free on the record path. Thread-safe (C mutex).
// C ABI uses void* handles; Swift stores UnsafeMutableRawPointer.
final class TunnelFlightRecorder: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let identity = ProviderProcessIdentity.shared

    init?(path: String) {
        guard let h = path.withCString({ fptn_flight_recorder_create($0) }) else {
            return nil
        }
        handle = h
    }

    deinit {
        fptn_flight_recorder_destroy(handle)
    }

    @inline(__always)
    func record(
        _ code: TunnelFlightEventCode,
        generation: UInt32 = 0,
        flags: UInt16 = 0,
        value0: UInt64 = 0,
        value1: UInt64 = 0,
        value2: UInt64 = 0,
        synchronize: Bool = false
    ) -> UInt64 {
        fptn_flight_recorder_record(
            handle, code.rawValue, flags, generation,
            identity.processToken, 0, mach_continuous_time(),
            value0, value1, value2, synchronize ? 1 : 0
        )
    }

    @inline(__always)
    func recordForSession(
        _ code: TunnelFlightEventCode,
        sessionToken: UInt64,
        generation: UInt32 = 0,
        flags: UInt16 = 0,
        value0: UInt64 = 0,
        value1: UInt64 = 0,
        value2: UInt64 = 0,
        synchronize: Bool = false
    ) -> UInt64 {
        fptn_flight_recorder_record(
            handle, code.rawValue, flags, generation,
            identity.processToken, sessionToken, mach_continuous_time(),
            value0, value1, value2, synchronize ? 1 : 0
        )
    }

    func flush() -> Bool {
        fptn_flight_recorder_flush(handle) != 0
    }
}

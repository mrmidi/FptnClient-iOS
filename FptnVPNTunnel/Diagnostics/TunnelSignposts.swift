#if FPTN_SIGNPOSTS
import OSLog

// PR3A: Instruments signposts for tunnel lifecycle profiling.
// Compiled only in Debug and Measurement builds.
// Numeric metadata only — no interpolated strings.
enum TunnelSignposts {
    static let signposter = OSSignposter(
        subsystem: "net.mrmidi.FptnVPN.FptnVPNTunnel",
        category: "TunnelLifecycle"
    )

    // MARK: - Intervals

    static func beginTunnelStartup() -> OSSignpostIntervalState {
        signposter.beginInterval("TunnelStartup")
    }

    static func endTunnelStartup(_ state: OSSignpostIntervalState) {
        signposter.endInterval("TunnelStartup", state)
    }

    static func beginBridgeLifetime(generation: Int) -> (OSSignpostID, OSSignpostIntervalState) {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("BridgeLifetime", id: id)
        return (id, state)
    }

    static func endBridgeLifetime(_ state: OSSignpostIntervalState, generation: Int) {
        signposter.endInterval("BridgeLifetime", state)
    }

    static func beginNativeTeardown(generation: Int) -> (OSSignpostID, OSSignpostIntervalState) {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("NativeTeardown", id: id)
        return (id, state)
    }

    static func endNativeTeardown(_ state: OSSignpostIntervalState, generation: Int, activeOps: UInt32) {
        signposter.endInterval("NativeTeardown", state)
    }

    static func beginTunnelShutdown() -> OSSignpostIntervalState {
        signposter.beginInterval("TunnelShutdown")
    }

    static func endTunnelShutdown(_ state: OSSignpostIntervalState) {
        signposter.endInterval("TunnelShutdown", state)
    }

    static func beginReconnectDelay(attempt: Int) -> (OSSignpostID, OSSignpostIntervalState) {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("ReconnectDelay", id: id)
        return (id, state)
    }

    static func endReconnectDelay(_ state: OSSignpostIntervalState, attempt: Int) {
        signposter.endInterval("ReconnectDelay", state)
    }

    static func beginReadLoopLifetime() -> OSSignpostIntervalState {
        signposter.beginInterval("ReadLoopLifetime")
    }

    static func endReadLoopLifetime(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ReadLoopLifetime", state)
    }

    // MARK: - Point events

    static func transportConnected(generation: Int) {
        signposter.emitEvent("TransportConnected")
    }

    static func transportDisconnected(generation: Int) {
        signposter.emitEvent("TransportDisconnected")
    }

    static func networkPathChanged(satisfied: Bool) {
        signposter.emitEvent("NetworkPathChanged")
    }

    static func memoryWarning() {
        signposter.emitEvent("MemoryWarning")
    }

    static func invariantViolation() {
        signposter.emitEvent("InvariantViolation")
    }
}
#endif

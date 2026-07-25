import Foundation

/// Maps an `NEProviderStopReason` raw value to a readable name. Lives in
/// SharedTunnelRuntime so both the app and the tunnel extension can use it —
/// the provider logs it in `stopTunnel`, the app surfaces it in diagnostics.
enum TunnelStopReasonDescription {
    static func describe(rawValue: Int) -> String {
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
}

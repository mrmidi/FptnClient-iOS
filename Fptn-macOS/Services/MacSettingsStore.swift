import Foundation
import FptnSharedCore
import FptnSharedTunnel

enum MacSettingsStore {
    private static let tokenKey = "fptn.macos.token"
    private static let sniKey = "fptn.macos.sni"
    private static let selectedServerKey = "fptn.macos.selectedServer"
    private static let routePushThroughTunnelKey = "fptn.macos.routePushThroughTunnel"
    private static let censorshipStrategyKey = "fptn.macos.censorshipStrategy"
    private static let dataPlaneModeKey = "fptn.macos.dataPlaneMode"
    private static let logLevelKey = "fptn.macos.logLevel"

    static func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
    }

    static func readToken() -> String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    static func saveSni(_ sni: String) {
        UserDefaults.standard.set(sni, forKey: sniKey)
    }

    static func readSni() -> String {
        UserDefaults.standard.string(forKey: sniKey) ?? "rutube.ru"
    }

    static func saveSelectedServer(_ serverID: String?) {
        UserDefaults.standard.set(serverID, forKey: selectedServerKey)
    }

    static func readSelectedServerID() -> String? {
        UserDefaults.standard.string(forKey: selectedServerKey)
    }

    static func saveRoutePushThroughTunnel(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: routePushThroughTunnelKey)
    }

    /// Defaults to ON when unset.
    static func readRoutePushThroughTunnel() -> Bool {
        let stored = UserDefaults.standard.object(forKey: routePushThroughTunnelKey)
        return stored == nil ? true : UserDefaults.standard.bool(forKey: routePushThroughTunnelKey)
    }

    static func saveDataPlaneMode(_ mode: TunnelDataPlaneMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: dataPlaneModeKey)
    }

    /// Defaults to `l3Tunnel`, and clamps the same way iOS does: `flowProxy`
    /// routes every flow off-device and would expose the real IP while the UI
    /// still reported a healthy tunnel, so a value a debug build persisted is
    /// never honoured by a release build. The tunnel clamps again on its own
    /// side -- this is the app-side half of the same rule.
    static func readDataPlaneMode() -> TunnelDataPlaneMode {
        let stored = UserDefaults.standard.string(forKey: dataPlaneModeKey)
            .flatMap(TunnelDataPlaneMode.init(rawValue:)) ?? .l3Tunnel
        #if DEBUG
        return stored
        #else
        return stored.isReleaseSafe ? stored : .l3Tunnel
        #endif
    }

    static func saveLogLevel(_ level: SharedLogLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: logLevelKey)
    }

    /// Defaults to `info`, not `warning`. The periodic funnel counters -- the
    /// only window into whether packets reach the stack and come back -- are
    /// logged at info, so a `warning` default makes the tunnel look silent
    /// even while it is working. macOS previously hardcoded `warning` with no
    /// way to change it, so those lines could never appear at all.
    static func readLogLevel() -> SharedLogLevel {
        guard let raw = UserDefaults.standard.string(forKey: logLevelKey),
              let level = SharedLogLevel(rawValue: raw) else {
            return .info
        }
        return level
    }

    static func saveCensorshipStrategy(_ strategy: CensorshipStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: censorshipStrategyKey)
    }

    /// Defaults to SNI, which is what the native library falls back to for an
    /// unrecognised value anyway.
    static func readCensorshipStrategy() -> CensorshipStrategy {
        guard let raw = UserDefaults.standard.string(forKey: censorshipStrategyKey),
              let strategy = CensorshipStrategy(rawValue: raw) else {
            return .sniSpoofing
        }
        return strategy
    }
}

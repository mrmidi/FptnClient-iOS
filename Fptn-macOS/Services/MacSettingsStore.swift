import Foundation
import FptnSharedCore

enum MacSettingsStore {
    private static let tokenKey = "fptn.macos.token"
    private static let sniKey = "fptn.macos.sni"
    private static let selectedServerKey = "fptn.macos.selectedServer"
    private static let routePushThroughTunnelKey = "fptn.macos.routePushThroughTunnel"
    private static let censorshipStrategyKey = "fptn.macos.censorshipStrategy"

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

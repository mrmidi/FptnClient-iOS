/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedTunnel

actor SettingsService {
    static let shared = SettingsService()

    private static let sniKey                = "fptn.settings.sni"
    private static let autoConnectKey        = "fptn.settings.autoConnect"
    private static let bypassMethodKey       = "fptn.settings.bypassMethod"
    private static let reconnectEnabledKey   = "fptn.settings.reconnectEnabled"
    private static let maxReconnectKey       = "fptn.settings.maxReconnectAttempts"
    private static let reconnectDelayKey     = "fptn.settings.reconnectDelay"
    private static let websocketIdleTimeoutKey = "fptn.settings.websocketIdleTimeoutSeconds"
    private static let colorSchemeKey        = "fptn.settings.colorScheme"
    private static let logLevelKey           = "fptn.settings.logLevel"
    private static let routePushThroughTunnelKey = "fptn.settings.routePushThroughTunnel"
    private static let customDnsEnabledKey  = "fptn.settings.customDnsEnabled"
    private static let customDnsIPv4Key     = "fptn.settings.customDnsIPv4"
    private static let flowDataPlaneEnabledKey = "fptn.settings.flowDataPlaneEnabled"
    fileprivate static let dataPlaneModeKey = "fptn.settings.dataPlaneMode"

    // MARK: - Nonisolated reads (UserDefaults is thread-safe)

    nonisolated var sni: String {
        UserDefaults.standard.string(forKey: Self.sniKey) ?? "rutube.ru"
    }

    nonisolated var autoConnect: Bool {
        UserDefaults.standard.bool(forKey: Self.autoConnectKey)
    }

    nonisolated var censorshipStrategy: CensorshipStrategy {
        CensorshipStrategy(storedValue: UserDefaults.standard.string(forKey: Self.bypassMethodKey))
    }

    nonisolated var bypassMethod: BypassMethod {
        censorshipStrategy
    }

    nonisolated var reconnectEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: Self.reconnectEnabledKey)
        return stored == nil ? true : UserDefaults.standard.bool(forKey: Self.reconnectEnabledKey)
    }

    /// 0 = infinite
    nonisolated var maxReconnectAttempts: Int {
        let stored = UserDefaults.standard.object(forKey: Self.maxReconnectKey)
        return stored == nil ? 0 : UserDefaults.standard.integer(forKey: Self.maxReconnectKey)
    }

    /// Seconds between reconnect attempts
    nonisolated var reconnectDelay: Int {
        let stored = UserDefaults.standard.object(forKey: Self.reconnectDelayKey)
        return stored == nil ? 2 : UserDefaults.standard.integer(forKey: Self.reconnectDelayKey)
    }

    /// Seconds before the native tunnel websocket is considered idle.
    nonisolated var websocketIdleTimeoutSeconds: Int {
        let stored = UserDefaults.standard.object(forKey: Self.websocketIdleTimeoutKey)
        return stored == nil ? 60 : UserDefaults.standard.integer(forKey: Self.websocketIdleTimeoutKey)
    }

    nonisolated var colorScheme: AppColorScheme {
        guard let raw = UserDefaults.standard.string(forKey: Self.colorSchemeKey),
              let scheme = AppColorScheme(rawValue: raw) else { return .system }
        return scheme
    }

    nonisolated var logLevel: LogLevel {
        guard let raw = UserDefaults.standard.string(forKey: Self.logLevelKey),
              let level = LogLevel(rawValue: raw) else { return .info }
        return level
    }

    /// When enabled, APNs (push) traffic is forced through the tunnel via
    /// `includeAllNetworks` + `excludeAPNs = false`. Defaults to ON.
    nonisolated var routePushThroughTunnel: Bool {
        let stored = UserDefaults.standard.object(forKey: Self.routePushThroughTunnelKey)
        return stored == nil ? true : UserDefaults.standard.bool(forKey: Self.routePushThroughTunnelKey)
    }

    nonisolated var customDnsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.customDnsEnabledKey)
    }

    nonisolated var customDnsIPv4: String {
        UserDefaults.standard.string(forKey: Self.customDnsIPv4Key) ?? ""
    }

    nonisolated var flowDataPlaneEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.flowDataPlaneEnabledKey)
    }

    /// The persisted data plane, already clamped to something this build may
    /// run. A debug build can persist `flowProxy`, which routes every flow
    /// direct and would expose the user's real IP; a later release build must
    /// never honour it, and hiding the UI is not sufficient. Clamping lands on
    /// `l3Tunnel` — the safest mode, not `split`.
    nonisolated var dataPlaneMode: TunnelDataPlaneMode {
        let stored = UserDefaults.standard.string(forKey: Self.dataPlaneModeKey)
            .flatMap(TunnelDataPlaneMode.init(rawValue:))
            ?? Self.migratedDataPlaneMode
        #if DEBUG
        return stored
        #else
        return stored.isReleaseSafe ? stored : .l3Tunnel
        #endif
    }

    /// One-time read of the superseded boolean so an existing install keeps
    /// the mode it was already running.
    private nonisolated static var migratedDataPlaneMode: TunnelDataPlaneMode {
        UserDefaults.standard.bool(forKey: flowDataPlaneEnabledKey)
            ? .flowProxy
            : .l3Tunnel
    }

    // MARK: - Setters

    func setSni(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.sniKey)
    }

    func setAutoConnect(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.autoConnectKey)
    }

    func setCensorshipStrategy(_ strategy: CensorshipStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: Self.bypassMethodKey)
    }

    func setBypassMethod(_ method: BypassMethod) {
        setCensorshipStrategy(method)
    }

    func setReconnectEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.reconnectEnabledKey)
    }

    func setMaxReconnectAttempts(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.maxReconnectKey)
    }

    func setReconnectDelay(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.reconnectDelayKey)
    }

    func setWebsocketIdleTimeoutSeconds(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.websocketIdleTimeoutKey)
    }

    func setColorScheme(_ scheme: AppColorScheme) {
        UserDefaults.standard.set(scheme.rawValue, forKey: Self.colorSchemeKey)
    }

    func setLogLevel(_ level: LogLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: Self.logLevelKey)
    }

    func setRoutePushThroughTunnel(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.routePushThroughTunnelKey)
    }

    func setCustomDnsEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.customDnsEnabledKey)
    }

    func setCustomDnsIPv4(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.customDnsIPv4Key)
    }

    func setFlowDataPlaneEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.flowDataPlaneEnabledKey)
    }

    func setDataPlaneMode(_ value: TunnelDataPlaneMode) {
        UserDefaults.standard.set(value.rawValue, forKey: Self.dataPlaneModeKey)
    }

    // MARK: - SNI sanitization

    /// Strips URL prefixes/paths and normalises to a bare hostname.
    /// e.g. "https://WWW.EXAMPLE.COM/path" → "example.com"
    nonisolated static func sanitizeSNI(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Strip scheme prefixes
        for prefix in ["https://", "http://", "ftp://"] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }

        // Strip www. prefix
        if result.hasPrefix("www.") {
            result = String(result.dropFirst(4))
        }

        // Strip path
        if let slashIdx = result.firstIndex(of: "/") {
            result = String(result[result.startIndex..<slashIdx])
        }

        // Keep only alphanumeric, dots, and hyphens
        result = result.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }

        return result
    }
}

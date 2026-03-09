/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

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

    // MARK: - Nonisolated reads (UserDefaults is thread-safe)

    nonisolated var sni: String {
        UserDefaults.standard.string(forKey: Self.sniKey) ?? "rutube.ru"
    }

    nonisolated var autoConnect: Bool {
        UserDefaults.standard.bool(forKey: Self.autoConnectKey)
    }

    nonisolated var bypassMethod: BypassMethod {
        guard let raw = UserDefaults.standard.string(forKey: Self.bypassMethodKey),
              let method = BypassMethod(rawValue: raw) else { return .sniSpoofing }
        return method
    }

    nonisolated var reconnectEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: Self.reconnectEnabledKey)
        return stored == nil ? true : UserDefaults.standard.bool(forKey: Self.reconnectEnabledKey)
    }

    /// 0 = infinite
    nonisolated var maxReconnectAttempts: Int {
        let stored = UserDefaults.standard.object(forKey: Self.maxReconnectKey)
        return stored == nil ? 5 : UserDefaults.standard.integer(forKey: Self.maxReconnectKey)
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

    // MARK: - Setters

    func setSni(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.sniKey)
    }

    func setAutoConnect(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.autoConnectKey)
    }

    func setBypassMethod(_ method: BypassMethod) {
        UserDefaults.standard.set(method.rawValue, forKey: Self.bypassMethodKey)
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

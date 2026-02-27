/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

/// Service that persists per-app VPN filter selections.
///
/// Full packet-level enforcement requires the `com.apple.developer.networking.vpn.api`
/// entitlement or MDM configuration. This service provides the data model and
/// persistence; the tunnel extension reads the values from `providerConfiguration`.
actor AppFilterService {
    static let shared = AppFilterService()

    private static let modeKey     = "fptn.appFilter.mode"
    private static let selectedKey = "fptn.appFilter.selectedBundleIDs"
    private static let appsKey     = "fptn.appFilter.apps"

    // MARK: - Nonisolated reads (UserDefaults is thread-safe)

    nonisolated var mode: PerAppVPNMode {
        guard let raw = UserDefaults.standard.string(forKey: Self.modeKey),
              let m = PerAppVPNMode(rawValue: raw) else { return .off }
        return m
    }

    nonisolated var selectedBundleIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? []
    }

    // MARK: - Setters

    func setMode(_ value: PerAppVPNMode) {
        UserDefaults.standard.set(value.rawValue, forKey: Self.modeKey)
    }

    func loadApps() -> [AppFilter] {
        if let data = UserDefaults.standard.data(forKey: Self.appsKey),
           let saved = try? JSONDecoder().decode([AppFilter].self, from: data) {
            return saved
        }
        return Self.fallbackApps()
    }

    func saveApps(_ apps: [AppFilter]) {
        let ids = apps.filter(\.isSelected).map(\.bundleID)
        UserDefaults.standard.set(ids, forKey: Self.selectedKey)
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: Self.appsKey)
        }
    }

    // MARK: - Fallback list (used when LSApplicationWorkspace is unavailable)

    /// A representative set of common iOS apps. Replace with a dynamic query
    /// via `LSApplicationWorkspace` once the private-API entitlement is available.
    private static func fallbackApps() -> [AppFilter] {
        [
            AppFilter(bundleID: "com.apple.mobilesafari",    displayName: "Safari",      isSelected: false),
            AppFilter(bundleID: "com.apple.mobilemail",      displayName: "Mail",        isSelected: false),
            AppFilter(bundleID: "com.apple.Maps",            displayName: "Maps",        isSelected: false),
            AppFilter(bundleID: "com.apple.AppStore",        displayName: "App Store",   isSelected: false),
            AppFilter(bundleID: "com.telegram.TelegramApp",  displayName: "Telegram",    isSelected: false),
            AppFilter(bundleID: "com.atebits.Tweetie2",      displayName: "X (Twitter)", isSelected: false),
            AppFilter(bundleID: "com.google.chrome.ios",     displayName: "Chrome",      isSelected: false),
            AppFilter(bundleID: "com.burbn.instagram",       displayName: "Instagram",   isSelected: false),
            AppFilter(bundleID: "com.zhiliaoapp.musically",  displayName: "TikTok",      isSelected: false),
            AppFilter(bundleID: "com.google.Gmail",          displayName: "Gmail",       isSelected: false),
            AppFilter(bundleID: "ru.vk.vkclient",            displayName: "VK",          isSelected: false),
            AppFilter(bundleID: "ru.ok.odnoklassniki",       displayName: "OK",          isSelected: false),
        ]
    }
}

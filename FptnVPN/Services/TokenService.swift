/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

actor TokenService {
    static let shared = TokenService()

    // MARK: - Storage keys (UserDefaults — local cache)

    private static let tokenKey = "fptnTokenData"
    private static let serversKey = "vpnServers"
    private static let usernameKey = "vpnUsername"
    private static let passwordKey = "vpnPassword"
    private static let serviceNameKey = "serviceName"

    /// Flag set when local cache was populated from iCloud KVS data.
    private static let cloudOriginKey = "fptn.cloudOrigin"

    // MARK: - iCloud KVS keys (synced across devices)

    private static let cloudTokenKey = "fptn.cloud.tokenData"
    private static let cloudServersKey = "fptn.cloud.servers"
    private static let cloudUsernameKey = "fptn.cloud.username"
    private static let cloudServiceNameKey = "fptn.cloud.serviceName"

    nonisolated(unsafe) private static let cloud = NSUbiquitousKeyValueStore.default

    // MARK: - Save

    func saveTokenData(_ tokenData: FPTNToken) {
        let encoder = JSONEncoder()

        // -- Local UserDefaults (immediate access) --
        if let encodedToken = try? encoder.encode(tokenData) {
            UserDefaults.standard.set(encodedToken, forKey: Self.tokenKey)
        }
        if let encodedServers = try? encoder.encode(tokenData.servers) {
            UserDefaults.standard.set(encodedServers, forKey: Self.serversKey)
        }
        UserDefaults.standard.set(tokenData.username, forKey: Self.usernameKey)
        UserDefaults.standard.set(tokenData.service_name, forKey: Self.serviceNameKey)

        // -- iCloud Keychain (password syncs across devices) --
        if let passwordData = tokenData.password.data(using: .utf8) {
            KeychainHelper.savePassword(passwordData, account: tokenData.username)
        }

        // -- iCloud KVS (non-secret metadata syncs across devices) --
        // Token without password — we never put the password in KVS.
        let tokenForCloud = FPTNToken(
            version: tokenData.version,
            service_name: tokenData.service_name,
            username: tokenData.username,
            password: "",
            servers: tokenData.servers
        )
        if let cloudData = try? encoder.encode(tokenForCloud) {
            Self.cloud.set(cloudData, forKey: Self.cloudTokenKey)
        }
        if let serversData = try? encoder.encode(tokenData.servers) {
            Self.cloud.set(serversData, forKey: Self.cloudServersKey)
        }
        Self.cloud.set(tokenData.username, forKey: Self.cloudUsernameKey)
        Self.cloud.set(tokenData.service_name, forKey: Self.cloudServiceNameKey)
        Self.cloud.synchronize()
    }

    // MARK: - Read

    func getTokenData() -> FPTNToken? {
        // Try local first, fall back to iCloud KVS for cross-device scenario.
        let data = UserDefaults.standard.data(forKey: Self.tokenKey)
                ?? Self.cloud.data(forKey: Self.cloudTokenKey)

        guard let data,
              var token = try? JSONDecoder().decode(FPTNToken.self, from: data) else {
            return nil
        }

        // Restore password from iCloud Keychain.
        if let passwordData = KeychainHelper.loadPassword(account: token.username),
           let password = String(data: passwordData, encoding: .utf8) {
            token = FPTNToken(
                version: token.version,
                service_name: token.service_name,
                username: token.username,
                password: password,
                servers: token.servers
            )
        }

        // If we loaded from iCloud but local is empty, populate local cache
        // and mark that the token originated from iCloud sync.
        if UserDefaults.standard.data(forKey: Self.tokenKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.cloudOriginKey)
            if let encoded = try? JSONEncoder().encode(token) {
                UserDefaults.standard.set(encoded, forKey: Self.tokenKey)
            }
            if let encoded = try? JSONEncoder().encode(token.servers) {
                UserDefaults.standard.set(encoded, forKey: Self.serversKey)
            }
            UserDefaults.standard.set(token.username, forKey: Self.usernameKey)
            UserDefaults.standard.set(token.service_name, forKey: Self.serviceNameKey)
        }

        return token
    }

    func getServers() -> [VPNServer] {
        let data = UserDefaults.standard.data(forKey: Self.serversKey)
                ?? Self.cloud.data(forKey: Self.cloudServersKey)

        guard let data,
              let servers = try? JSONDecoder().decode([VPNServer].self, from: data) else {
            return []
        }
        return servers
    }

    /// Synchronous check — safe to call without `await` because it only reads
    /// from UserDefaults and iCloud KVS (both thread-safe) via static keys.
    nonisolated func isLoggedIn() -> Bool {
        UserDefaults.standard.data(forKey: Self.tokenKey) != nil
            || Self.cloud.data(forKey: Self.cloudTokenKey) != nil
    }

    /// True when the token was originally received from iCloud (either at
    /// launch via KVS fallback or via a live cloud-change notification).
    nonisolated func wasCloudSynced() -> Bool {
        UserDefaults.standard.bool(forKey: Self.cloudOriginKey)
    }

    // MARK: - Clear

    func clearTokenData() {
        if let username = UserDefaults.standard.string(forKey: Self.usernameKey)
                       ?? Self.cloud.string(forKey: Self.cloudUsernameKey) {
            KeychainHelper.deletePassword(account: username)
        }

        // Local
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.serversKey)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        UserDefaults.standard.removeObject(forKey: Self.passwordKey)
        UserDefaults.standard.removeObject(forKey: Self.serviceNameKey)
        UserDefaults.standard.removeObject(forKey: Self.cloudOriginKey)

        // iCloud KVS
        Self.cloud.removeObject(forKey: Self.cloudTokenKey)
        Self.cloud.removeObject(forKey: Self.cloudServersKey)
        Self.cloud.removeObject(forKey: Self.cloudUsernameKey)
        Self.cloud.removeObject(forKey: Self.cloudServiceNameKey)
        Self.cloud.synchronize()
    }

    // MARK: - iCloud KVS observation

    /// Call once at app launch to pull any data that arrived while the app was
    /// not running and to begin observing remote changes.
    nonisolated func startCloudSync() {
        Self.cloud.synchronize()

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: Self.cloud,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            // Extract changed keys on this thread (Notification is not Sendable).
            let changedKeys = (notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            Task { await self.handleCloudChange(changedKeys: changedKeys) }
        }
    }

    private func handleCloudChange(changedKeys: [String]) {
        let relevantKeys: Set<String> = [
            Self.cloudTokenKey, Self.cloudServersKey,
            Self.cloudUsernameKey, Self.cloudServiceNameKey
        ]
        guard !changedKeys.filter({ relevantKeys.contains($0) }).isEmpty else { return }

        // Refresh local cache from iCloud KVS and mark cloud origin.
        if let data = Self.cloud.data(forKey: Self.cloudTokenKey) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
            UserDefaults.standard.set(true, forKey: Self.cloudOriginKey)
        }
        if let data = Self.cloud.data(forKey: Self.cloudServersKey) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
        if let username = Self.cloud.string(forKey: Self.cloudUsernameKey) {
            UserDefaults.standard.set(username, forKey: Self.usernameKey)
        }
        if let serviceName = Self.cloud.string(forKey: Self.cloudServiceNameKey) {
            UserDefaults.standard.set(serviceName, forKey: Self.serviceNameKey)
        }
    }
}

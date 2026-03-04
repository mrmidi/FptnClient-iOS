import Foundation

/// Reads FPTN token metadata from iCloud Key-Value Store.
/// Uses the same keys as the iOS TokenService so data syncs cross-platform.
enum TvCloudTokenSync {
    private static let cloud = NSUbiquitousKeyValueStore.default

    // Must match the keys in TokenService (iOS).
    private static let tokenKey = "fptn.cloud.tokenData"
    private static let serversKey = "fptn.cloud.servers"
    private static let usernameKey = "fptn.cloud.username"
    private static let serviceNameKey = "fptn.cloud.serviceName"

    /// Kick off iCloud KVS sync and register for remote change notifications.
    static func startObserving(onChange: @escaping () -> Void) {
        cloud.synchronize()

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
                return
            }
            let relevant: Set<String> = [tokenKey, serversKey, usernameKey, serviceNameKey]
            if !keys.filter({ relevant.contains($0) }).isEmpty {
                onChange()
            }
        }
    }

    /// Returns the synced token payload, or nil if nothing is in iCloud KVS.
    /// The password field will be empty — retrieve it from the keychain separately.
    static func loadTokenPayload() -> TvTokenPayload? {
        guard let data = cloud.data(forKey: tokenKey) else { return nil }
        return try? JSONDecoder().decode(TvTokenPayload.self, from: data)
    }

    /// Reads the password from the shared iCloud Keychain for the given username.
    static func loadPassword(username: String) -> String? {
        TvKeychainStore.read(
            service: "org.fptn.credentials",
            account: username
        )
    }
}

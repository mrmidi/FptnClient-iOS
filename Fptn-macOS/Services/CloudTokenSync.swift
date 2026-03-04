import Foundation
import FptnSharedCore

/// Reads and writes FPTN token metadata from iCloud Key-Value Store.
/// Uses the same keys as the iOS TokenService so data syncs cross-platform.
enum CloudTokenSync {
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
    static func loadTokenPayload() -> MacTokenPayload? {
        guard let data = cloud.data(forKey: tokenKey) else { return nil }

        // The iOS side stores FPTNToken (with VPNServer), which has the same
        // JSON shape as MacTokenPayload (with MacVPNServer). Decode directly.
        return try? JSONDecoder().decode(MacTokenPayload.self, from: data)
    }

    /// Reads the password from the shared iCloud Keychain for the given username.
    static func loadPassword(username: String) -> String? {
        MacKeychainStore.read(
            service: "org.fptn.credentials",
            account: username
        )
    }

    /// Saves token metadata to iCloud KVS (called after local login on macOS).
    static func saveTokenPayload(_ token: MacTokenPayload) {
        let encoder = JSONEncoder()
        // Store without password in KVS.
        let stripped = MacTokenPayload(
            version: token.version,
            service_name: token.service_name,
            username: token.username,
            password: "",
            servers: token.servers
        )
        if let data = try? encoder.encode(stripped) {
            cloud.set(data, forKey: tokenKey)
        }
        if let data = try? encoder.encode(token.servers) {
            cloud.set(data, forKey: serversKey)
        }
        cloud.set(token.username, forKey: usernameKey)
        cloud.set(token.service_name, forKey: serviceNameKey)
        cloud.synchronize()
    }

    /// Saves the password to the shared iCloud Keychain.
    static func savePassword(_ password: String, username: String) {
        MacKeychainStore.save(
            service: "org.fptn.credentials",
            account: username,
            value: password
        )
    }
}

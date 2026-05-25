import Foundation
import FptnSharedCore
import OSLog

/// Reads FPTN token metadata from iCloud Key-Value Store.
/// Uses the same keys as the iOS TokenService so data syncs cross-platform.
enum TvCloudTokenSync {
    private static let log = Logger(subsystem: "net.mrmidi.Fptn-tvOS", category: "CloudSync")
    nonisolated(unsafe) private static let cloud = NSUbiquitousKeyValueStore.default

    // Must match the keys in TokenService (iOS).
    private static let tokenKey = "fptn.cloud.tokenData"
    private static let serversKey = "fptn.cloud.servers"
    private static let usernameKey = "fptn.cloud.username"
    private static let serviceNameKey = "fptn.cloud.serviceName"
    private static let passwordKey = "fptn.cloud.password"

    /// Kick off iCloud KVS sync and register for remote change notifications.
    static func startObserving(onChange: @escaping @Sendable () -> Void) {
        let synced = cloud.synchronize()
        log.log("iCloud KVS synchronize() returned \(synced, privacy: .public)")

        // Dump all keys currently in the KVS store for debugging
        let allKeys = cloud.dictionaryRepresentation.keys.sorted()
        log.log("iCloud KVS has \(allKeys.count, privacy: .public) keys: \(allKeys.joined(separator: ", "), privacy: .public)")

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { notification in
            log.log("iCloud KVS external change received")
            guard let userInfo = notification.userInfo,
                  let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
                log.log("  No changed keys in notification")
                return
            }
            log.log("  Changed keys: \(keys.joined(separator: ", "), privacy: .public)")
            let relevant: Set<String> = [tokenKey, serversKey, usernameKey, serviceNameKey, passwordKey]
            if !keys.filter({ relevant.contains($0) }).isEmpty {
                onChange()
            }
        }
    }

    /// Returns the synced token payload, or nil if nothing is in iCloud KVS.
    /// The password field will be empty — retrieve it from the keychain separately.
    static func loadTokenPayload() -> TvTokenPayload? {
        let data = cloud.data(forKey: tokenKey)
        log.log("loadTokenPayload: tokenKey=\(tokenKey, privacy: .public) hasData=\(data != nil, privacy: .public)")
        if let data {
            log.log("  data size=\(data.count, privacy: .public) bytes")
            if let str = String(data: data, encoding: .utf8) {
                log.log("  raw JSON: \(str, privacy: .public)")
            }
        }

        // Also check individual keys for debugging
        let username = cloud.string(forKey: usernameKey)
        let serviceName = cloud.string(forKey: serviceNameKey)
        log.log("  username=\(username ?? "nil", privacy: .public) serviceName=\(serviceName ?? "nil", privacy: .public)")

        guard let data else { return nil }
        do {
            let token = try JSONDecoder().decode(TvTokenPayload.self, from: data)
            log.log("  Decoded token: user=\(token.username, privacy: .public) servers=\(token.servers.count, privacy: .public)")
            return token
        } catch {
            log.error("  Failed to decode token: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Reads the password for the given username.
    /// First checks iCloud Keychain; falls back to iCloud KVS if Keychain hasn't synced yet.
    /// Returns `(password, found: true)` when the credential is available,
    /// or `(nil, found: false)` when it hasn't arrived on this device yet.
    static func loadPassword(username: String) -> (password: String?, found: Bool) {
        let keychain = TvKeychainStore.readWithStatus(
            service: "net.mrmidi.fptn.credentials",
            account: username
        )
        let found = keychain.status == errSecSuccess
        log.log("loadPassword: username=\(username, privacy: .public) found=\(found, privacy: .public) status=\(keychain.status, privacy: .public)")
        if found {
            return (keychain.value, true)
        }

        // iCloud Keychain sync can be delayed — fall back to KVS password set by iOS app.
        if let kvsPassword = cloud.string(forKey: passwordKey) {
            log.log("loadPassword: using KVS fallback password (Keychain not synced yet)")
            return (kvsPassword, true)
        }

        return (nil, false)
    }
}

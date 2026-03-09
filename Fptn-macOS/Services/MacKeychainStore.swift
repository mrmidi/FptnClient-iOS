import Foundation
import Security

enum MacKeychainStore {
    /// Same access group used by the iOS app and all tunnel extensions.
    static let accessGroup = "F6YA6B56LR.group.net.mrmidi.FptnVPN"

    static func save(service: String, account: String, value: String) {
        migrateIfNeeded(service: service, account: account)
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        readWithStatus(service: service, account: account).value
    }

    static func readWithStatus(service: String, account: String) -> (value: String?, status: OSStatus) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return (nil, status)
        }
        return (text, status)
    }

    static func delete(service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Migrates an item stored under the old service name to the current one.
    private static func migrateIfNeeded(service: String, account: String) {
        // Already exists under the new service name? Nothing to do.
        var check = baseQuery(service: service, account: account)
        check[kSecReturnData as String] = true
        check[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(check as CFDictionary, nil) == errSecSuccess { return }

        // Derive old service name by replacing the known prefix.
        let oldService = service.replacingOccurrences(of: "net.mrmidi.fptn", with: "org.fptn")
        guard oldService != service else { return }

        var oldQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]

        var ref: AnyObject?
        guard SecItemCopyMatching(oldQuery as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return }

        // Write directly under new service name (bypass save() to avoid recursion).
        let newQuery = baseQuery(service: service, account: account)
        SecItemDelete(newQuery as CFDictionary)
        var addQuery = newQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return }

        // Delete old item.
        oldQuery.removeValue(forKey: kSecReturnData as String)
        oldQuery.removeValue(forKey: kSecMatchLimit as String)
        SecItemDelete(oldQuery as CFDictionary)
    }
}

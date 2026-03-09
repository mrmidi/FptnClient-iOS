import Foundation
import Security

enum TvKeychainStore {
    /// Same access group used by the iOS app and all tunnel extensions.
    static let accessGroup = "F6YA6B56LR.group.net.mrmidi.FptnVPN"

    static func read(service: String, account: String) -> String? {
        let result = readWithStatus(service: service, account: account)
        return result.value
    }

    static func readWithStatus(service: String, account: String) -> (value: String?, status: OSStatus) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let text = String(data: data, encoding: .utf8) {
            return (text, status)
        }

        // Fall back to old service name "org.fptn.credentials".
        let oldService = service.replacingOccurrences(of: "net.mrmidi.fptn", with: "org.fptn")
        if oldService != service {
            var oldQuery = baseQuery(service: oldService, account: account)
            oldQuery[kSecReturnData as String] = true
            oldQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            result = nil
            status = SecItemCopyMatching(oldQuery as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let text = String(data: data, encoding: .utf8) {
                return (text, status)
            }
        }

        return (nil, status)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true
        ]
    }
}

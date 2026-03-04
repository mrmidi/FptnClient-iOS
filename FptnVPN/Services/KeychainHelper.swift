/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Security

struct KeychainHelper {
    static let serviceName = "org.fptn.credentials"

    /// Shared app-group used as keychain access group so that the main app,
    /// tunnel extension, and macOS counterpart can all read the same items.
    static let accessGroup = "group.net.mrmidi.FptnVPN"

    // MARK: - Public API

    static func savePassword(_ passwordData: Data, account: String) {
        migrateIfNeeded(account: account)

        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = passwordData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadPassword(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            return dataTypeRef as? Data
        }
        return nil
    }

    static func deletePassword(account: String) {
        // Delete the synchronizable item in the shared group.
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        // Clean up any legacy non-sync item (shared-group but not synchronizable).
        var legacyShared: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        legacyShared[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(legacyShared as CFDictionary)

        // Clean up any legacy item without a group at all.
        let legacyPrivate: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacyPrivate as CFDictionary)
    }

    // MARK: - Private helpers

    /// Base query dictionary shared by all operations.
    /// Items are synchronizable (iCloud Keychain) and in the shared access group.
    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// Moves a legacy item into the synchronizable shared access group.
    /// Checks two legacy locations: shared-group-non-sync, and private (no group).
    private static func migrateIfNeeded(account: String) {
        // Already have a sync item? Nothing to do.
        var syncCheck = baseQuery(account: account)
        syncCheck[kSecReturnData as String] = true
        syncCheck[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(syncCheck as CFDictionary, nil) == errSecSuccess {
            return
        }

        // Try shared-group non-sync item first (from previous KeychainHelper version).
        var sharedNonSync: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(macOS)
        sharedNonSync[kSecUseDataProtectionKeychain as String] = true
        #endif

        var ref: AnyObject?
        if SecItemCopyMatching(sharedNonSync as CFDictionary, &ref) == errSecSuccess,
           let data = ref as? Data {
            writeAndCleanup(data: data, account: account, legacyQuery: sharedNonSync)
            return
        }

        // Try private (no group) item (original KeychainHelper).
        var privateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(macOS)
        privateQuery[kSecUseDataProtectionKeychain as String] = true
        #endif

        ref = nil
        if SecItemCopyMatching(privateQuery as CFDictionary, &ref) == errSecSuccess,
           let data = ref as? Data {
            writeAndCleanup(data: data, account: account, legacyQuery: privateQuery)
        }
    }

    private static func writeAndCleanup(data: Data, account: String, legacyQuery: [String: Any]) {
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            // Remove search-only keys before deleting.
            var deleteQuery = legacyQuery
            deleteQuery.removeValue(forKey: kSecReturnData as String)
            deleteQuery.removeValue(forKey: kSecMatchLimit as String)
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}

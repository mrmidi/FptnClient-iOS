/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

actor TokenService {
    static let shared = TokenService()

    // Static so they can be read from nonisolated contexts without await.
    private static let tokenKey = "fptnTokenData"
    private static let serversKey = "vpnServers"
    private static let usernameKey = "vpnUsername"
    private static let passwordKey = "vpnPassword"
    private static let serviceNameKey = "serviceName"

    func saveTokenData(_ tokenData: FPTNToken) {
        if let encodedToken = try? JSONEncoder().encode(tokenData) {
            UserDefaults.standard.set(encodedToken, forKey: Self.tokenKey)
        }

        if let encodedServers = try? JSONEncoder().encode(tokenData.servers) {
            UserDefaults.standard.set(encodedServers, forKey: Self.serversKey)
        }

        UserDefaults.standard.set(tokenData.username, forKey: Self.usernameKey)
        UserDefaults.standard.set(tokenData.service_name, forKey: Self.serviceNameKey)

        if let passwordData = tokenData.password.data(using: .utf8) {
            KeychainHelper.savePassword(passwordData, account: tokenData.username)
        }
    }

    func getTokenData() -> FPTNToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey),
              var token = try? JSONDecoder().decode(FPTNToken.self, from: data) else {
            return nil
        }

        // Restore password from Keychain if missing in UserDefaults
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

        return token
    }

    func getServers() -> [VPNServer] {
        guard let data = UserDefaults.standard.data(forKey: Self.serversKey),
              let servers = try? JSONDecoder().decode([VPNServer].self, from: data) else {
            return []
        }
        return servers
    }

    /// Synchronous check — safe to call without `await` because it only reads
    /// from UserDefaults (thread-safe) via a static key (no actor state).
    nonisolated func isLoggedIn() -> Bool {
        UserDefaults.standard.data(forKey: Self.tokenKey) != nil
    }

    func clearTokenData() {
        if let username = UserDefaults.standard.string(forKey: Self.usernameKey) {
            KeychainHelper.deletePassword(account: username)
        }

        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.serversKey)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        UserDefaults.standard.removeObject(forKey: Self.passwordKey) // for legacy cleanup
        UserDefaults.standard.removeObject(forKey: Self.serviceNameKey)
    }
}

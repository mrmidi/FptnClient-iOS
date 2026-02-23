/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class LoginViewModel: ObservableObject {

    // MARK: - Published state

    @Published var token = ""
    @Published private(set) var errorMessage: String? = nil
    @Published var isLoggedIn = false

    var isLoginButtonEnabled: Bool { !token.isEmpty }

    // MARK: - Dependencies

    private let tokenService: TokenService

    init(tokenService: TokenService = .shared) {
        self.tokenService = tokenService
    }

    // MARK: - Commands

    func login() async {
        errorMessage = nil

        guard token.hasPrefix("fptn:") else {
            errorMessage = "Invalid token format. Token should start with 'fptn:'"
            logger.warning("Login attempt with invalid token format")
            return
        }

        let base64String = String(token.dropFirst(5))
        let padded = addBase64Padding(base64String)

        guard let data = Data(base64Encoded: padded) else {
            errorMessage = "Invalid base64 encoding"
            logger.error("Token base64 decode failed")
            return
        }

        do {
            let tokenData = try JSONDecoder().decode(FPTNToken.self, from: data)
            await tokenService.saveTokenData(tokenData)
            logger.info("Login successful, servers: \(tokenData.servers.count)")
            isLoggedIn = true
        } catch {
            let msg = "Failed to parse token: \(error.localizedDescription)"
            logger.error("\(msg)")
            errorMessage = msg
        }
    }

    // MARK: - Private

    private func addBase64Padding(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder > 0 else { return value }
        return value + String(repeating: "=", count: 4 - remainder)
    }
}

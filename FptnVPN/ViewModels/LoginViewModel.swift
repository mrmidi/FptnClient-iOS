/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Compression
import Foundation

private enum LoginTokenParseError: LocalizedError {
    case empty
    case invalidBase64
    case brotliFailed(Error)
    case jsonDecodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Token is empty after removing prefix"
        case .invalidBase64:
            return "Invalid base64 encoding — check that you copied the full token from @fptn_bot"
        case .brotliFailed:
            return "Failed to decompress token — make sure you have the latest token from @fptn_bot"
        case .jsonDecodeFailed(let error):
            return "Failed to parse token: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class LoginViewModel: ObservableObject {

    // MARK: - Published state

    @Published var token = ""
    @Published private(set) var errorMessage: String? = nil
    @Published var isLoggedIn = false
    /// True when the token was loaded from iCloud rather than entered locally.
    @Published var isCloudSynced = false

    var isLoginButtonEnabled: Bool { !token.isEmpty }
    private var lastAutoLoginCandidate: String?

    // MARK: - Dependencies

    private let tokenService: TokenService

    private nonisolated(unsafe) var cloudObserver: Any?

    init(tokenService: TokenService = .shared) {
        self.tokenService = tokenService

        isLoggedIn = tokenService.isLoggedIn()
        isCloudSynced = tokenService.wasCloudSynced()

        // Listen for iCloud KVS changes that arrive after launch.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isLoggedIn && tokenService.isLoggedIn() {
                    self.isLoggedIn = true
                    self.isCloudSynced = true
                }
            }
        }
    }

    deinit {
        if let observer = cloudObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Commands

    func login() async {
        errorMessage = nil

        do {
            let tokenData = try decodeToken(token)
            await tokenService.saveTokenData(tokenData)
            logger.info("Login successful, servers: \(tokenData.servers.count)")
            isLoggedIn = true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("\(error.localizedDescription)")
        }
    }

    func shouldAutoLoginAfterTokenChange(from oldValue: String, to newValue: String) -> Bool {
        let addedCharacterCount = newValue.count - oldValue.count
        let looksPasted = oldValue.isEmpty || addedCharacterCount >= 16 || newValue.contains(where: \.isNewline)
        return !isLoggedIn && looksPasted && looksLikeToken(newValue)
    }

    func loginIfValidPastedToken(_ candidate: String) async {
        guard !isLoggedIn,
              candidate == token,
              candidate != lastAutoLoginCandidate else {
            return
        }

        lastAutoLoginCandidate = candidate
        do {
            let tokenData = try decodeToken(candidate)
            guard candidate == token else { return }
            await tokenService.saveTokenData(tokenData)
            logger.info("Auto-login successful, servers: \(tokenData.servers.count)")
            errorMessage = nil
            isLoggedIn = true
        } catch {
            logger.debug("Ignoring pasted token candidate: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func decodeToken(_ rawToken: String) throws -> FPTNToken {
        // Detect format before any prefix stripping.
        // fptnb: = base64(brotli(json))  — new format (bot commit d1ed549)
        // fptn:  = base64(json)          — legacy format
        let trimmed = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
        let isBrotli = trimmed.hasPrefix("fptnb:") || trimmed.hasPrefix("fptnb//")

        // Mirror C++ ConfigFile::Parse() sanitization:
        //   • strip fptnb: before fptn: so fptn: doesn't partially match fptnb:
        //   • collapse all whitespace
        //   • normalize URL-safe base64 chars (- → +, _ → /)
        //   • strip any existing = padding before re-adding the correct amount
        let sanitizedToken = trimmed
            .replacingOccurrences(of: "fptnb://", with: "")
            .replacingOccurrences(of: "fptnb:", with: "")
            .replacingOccurrences(of: "fptn://", with: "")
            .replacingOccurrences(of: "fptn:", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        guard !sanitizedToken.isEmpty else {
            throw LoginTokenParseError.empty
        }

        guard let compressed = Data(base64Encoded: addBase64Padding(sanitizedToken)) else {
            logger.error("Token base64 decode failed")
            throw LoginTokenParseError.invalidBase64
        }

        // Decompress if necessary, then decode JSON.
        let jsonData: Data
        if isBrotli {
            do {
                jsonData = try decompressBrotli(compressed)
                logger.debug("fptnb: Brotli decompressed \(compressed.count) → \(jsonData.count) bytes")
            } catch {
                logger.error("Brotli decompression failed: \(error.localizedDescription)")
                throw LoginTokenParseError.brotliFailed(error)
            }
        } else {
            jsonData = compressed
        }

        do {
            return try JSONDecoder().decode(FPTNToken.self, from: jsonData)
        } catch {
            throw LoginTokenParseError.jsonDecodeFailed(error)
        }
    }

    private func looksLikeToken(_ rawToken: String) -> Bool {
        let trimmed = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
        let hasKnownPrefix = trimmed.hasPrefix("fptn:")
            || trimmed.hasPrefix("fptn://")
            || trimmed.hasPrefix("fptnb:")
            || trimmed.hasPrefix("fptnb://")

        guard hasKnownPrefix else { return false }

        let payload = trimmed
            .replacingOccurrences(of: "fptnb://", with: "")
            .replacingOccurrences(of: "fptnb:", with: "")
            .replacingOccurrences(of: "fptn://", with: "")
            .replacingOccurrences(of: "fptn:", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()

        return payload.count >= 32
    }

    private func addBase64Padding(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder > 0 else { return value }
        return value + String(repeating: "=", count: 4 - remainder)
    }

    /// Brotli decompression via Apple's built-in Compression framework (iOS 13+).
    /// Allocates a generous output buffer — FPTN token JSON is at most a few KB.
    private func decompressBrotli(_ compressed: Data) throws -> Data {
        let capacity = max(compressed.count * 20, 65_536)
        var output = [UInt8](repeating: 0, count: capacity)

        let written: Int = compressed.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(
                &output, capacity,
                base.assumingMemoryBound(to: UInt8.self),
                compressed.count,
                nil,
                COMPRESSION_BROTLI
            )
        }

        guard written > 0 else {
            throw NSError(
                domain: "LoginViewModel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Brotli decompression returned 0 bytes — data may be corrupted"]
            )
        }
        return Data(output[..<written])
    }
}

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Compression
import Foundation

@MainActor
final class LoginViewModel: ObservableObject {

    // MARK: - Published state

    @Published var token = ""
    @Published private(set) var errorMessage: String? = nil
    @Published var isLoggedIn = false
    /// True when the token was loaded from iCloud rather than entered locally.
    @Published var isCloudSynced = false

    var isLoginButtonEnabled: Bool { !token.isEmpty }

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

        // Detect format before any prefix stripping.
        // fptnb: = base64(brotli(json))  — new format (bot commit d1ed549)
        // fptn:  = base64(json)          — legacy format
        let trimmed = token
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
            errorMessage = "Token is empty after removing prefix"
            return
        }

        guard let compressed = Data(base64Encoded: addBase64Padding(sanitizedToken)) else {
            errorMessage = "Invalid base64 encoding — check that you copied the full token from @fptn_bot"
            logger.error("Token base64 decode failed")
            return
        }

        // Decompress if necessary, then decode JSON.
        let jsonData: Data
        if isBrotli {
            do {
                jsonData = try decompressBrotli(compressed)
                logger.debug("fptnb: Brotli decompressed \(compressed.count) → \(jsonData.count) bytes")
            } catch {
                errorMessage = "Failed to decompress token — make sure you have the latest token from @fptn_bot"
                logger.error("Brotli decompression failed: \(error.localizedDescription)")
                return
            }
        } else {
            jsonData = compressed
        }

        do {
            let tokenData = try JSONDecoder().decode(FPTNToken.self, from: jsonData)
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

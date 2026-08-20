/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Compression
import Foundation

/// Why a pasted token could not be turned into an `FPTNToken`.
///
/// Each case maps to advice the user can act on — "copy the whole message" is
/// useful, "invalid base64" is not — so the messages are deliberately about
/// what to *do*, not about what failed internally.
enum TokenParseError: LocalizedError, Equatable {
    case empty
    case notAToken
    case invalidBase64
    case brotliFailed
    case jsonDecodeFailed(String)
    case noServers

    var errorDescription: String? {
        switch self {
        case .empty:
            return NSLocalizedString("Clipboard is empty — copy the token from @fptn_bot first", comment: "")
        case .notAToken:
            return NSLocalizedString("That doesn't look like an FPTN token", comment: "")
        case .invalidBase64:
            return NSLocalizedString("Token looks truncated — copy the whole message", comment: "")
        case .brotliFailed:
            return NSLocalizedString("Token format not recognized — request a fresh one", comment: "")
        case .jsonDecodeFailed:
            return NSLocalizedString("Token is damaged — request a fresh one from @fptn_bot", comment: "")
        case .noServers:
            return NSLocalizedString("Token has no servers — contact support", comment: "")
        }
    }
}

/// Parses the `fptn:` / `fptnb:` tokens handed out by `@fptn_bot`.
///
/// Extracted from `LoginViewModel` so login and the in-place token refresh in
/// Settings share one implementation — two copies of this sanitisation would
/// drift, and the sanitisation is the part that makes real tokens work.
enum TokenDecoder {

    /// Sanitisation mirrors the native `ConfigFile::Parse()`:
    ///   • strip `fptnb:` before `fptn:` so `fptn:` cannot partially match it
    ///   • collapse all whitespace (tokens get wrapped by chat clients)
    ///   • normalise URL-safe base64 (`-` → `+`, `_` → `/`)
    ///   • strip any existing `=` padding before re-adding the correct amount
    ///
    /// `fptnb:` = base64(brotli(json)), `fptn:` = base64(json).
    static func decode(_ rawToken: String) throws -> FPTNToken {
        let trimmed = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")

        guard !trimmed.isEmpty else { throw TokenParseError.empty }
        guard hasKnownPrefix(trimmed) else { throw TokenParseError.notAToken }

        let isBrotli = trimmed.hasPrefix("fptnb:") || trimmed.hasPrefix("fptnb://")
        let sanitized = stripPrefixes(trimmed)
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        guard !sanitized.isEmpty else { throw TokenParseError.empty }

        guard let compressed = Data(base64Encoded: addBase64Padding(sanitized)) else {
            throw TokenParseError.invalidBase64
        }

        let jsonData: Data
        if isBrotli {
            guard let decompressed = try? decompressBrotli(compressed) else {
                throw TokenParseError.brotliFailed
            }
            jsonData = decompressed
        } else {
            jsonData = compressed
        }

        let token: FPTNToken
        do {
            token = try JSONDecoder().decode(FPTNToken.self, from: jsonData)
        } catch {
            throw TokenParseError.jsonDecodeFailed(error.localizedDescription)
        }

        // A token that parses but carries no servers is useless, and failing
        // here is far kinder than a connect attempt that finds nothing to race.
        guard !token.servers.isEmpty else { throw TokenParseError.noServers }

        return token
    }

    /// Cheap shape check used to decide whether a paste is worth auto-applying.
    /// Never throws — callers use it to stay quiet, not to report.
    static func looksLikeToken(_ rawToken: String) -> Bool {
        let trimmed = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
        guard hasKnownPrefix(trimmed) else { return false }
        let payload = stripPrefixes(trimmed)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        return payload.count >= 32
    }

    // MARK: - Private

    private static func hasKnownPrefix(_ value: String) -> Bool {
        value.hasPrefix("fptn:") || value.hasPrefix("fptn://")
            || value.hasPrefix("fptnb:") || value.hasPrefix("fptnb://")
    }

    private static func stripPrefixes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "fptnb://", with: "")
            .replacingOccurrences(of: "fptnb:", with: "")
            .replacingOccurrences(of: "fptn://", with: "")
            .replacingOccurrences(of: "fptn:", with: "")
    }

    private static func addBase64Padding(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder > 0 else { return value }
        return value + String(repeating: "=", count: 4 - remainder)
    }

    /// Brotli via Apple's Compression framework (iOS 13+). FPTN token JSON is at
    /// most a few KB, so a generous fixed buffer avoids a resize loop.
    private static func decompressBrotli(_ compressed: Data) throws -> Data {
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

        guard written > 0 else { throw TokenParseError.brotliFailed }
        return Data(output[..<written])
    }
}

import Compression
import Foundation

enum MacTokenParser {
    static func parse(token: String) throws -> MacTokenPayload {
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
        let isBrotli = trimmed.hasPrefix("fptnb:") || trimmed.hasPrefix("fptnb//")

        let cleaned = sanitize(trimmed)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "MacTokenParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Token is empty after removing prefix"])
        }

        guard let decoded = Data(base64Encoded: addBase64Padding(cleaned)) else {
            throw NSError(domain: "MacTokenParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 encoding"])
        }

        let jsonData: Data
        if isBrotli {
            jsonData = try decompressBrotli(decoded)
        } else {
            jsonData = decoded
        }

        return try JSONDecoder().decode(MacTokenPayload.self, from: jsonData)
    }

    private static func sanitize(_ token: String) -> String {
        token
            .replacingOccurrences(of: "fptnb://", with: "")
            .replacingOccurrences(of: "fptnb:", with: "")
            .replacingOccurrences(of: "fptn://", with: "")
            .replacingOccurrences(of: "fptn:", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func addBase64Padding(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder > 0 else { return value }
        return value + String(repeating: "=", count: 4 - remainder)
    }

    private static func decompressBrotli(_ compressed: Data) throws -> Data {
        let capacity = max(compressed.count * 20, 65_536)
        var output = [UInt8](repeating: 0, count: capacity)

        let written: Int = compressed.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(
                &output,
                capacity,
                base.assumingMemoryBound(to: UInt8.self),
                compressed.count,
                nil,
                COMPRESSION_BROTLI
            )
        }

        guard written > 0 else {
            throw NSError(domain: "MacTokenParser", code: 3, userInfo: [NSLocalizedDescriptionKey: "Brotli decompression failed"])
        }

        return Data(output[..<written])
    }
}

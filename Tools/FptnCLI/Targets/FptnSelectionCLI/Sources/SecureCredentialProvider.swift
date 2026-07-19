/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Darwin
import FptnSharedCore
import Compression

public struct SecureCredentialProvider {
    public static func getCredentials() -> Credentials? {
        let env = ProcessInfo.processInfo.environment
        
        // 1. Try FPTN_TOKEN first
        if let tokenStr = env["FPTN_TOKEN"] {
            if let creds = parseToken(tokenStr) {
                return creds
            }
        }
        
        // 2. Try FPTN_USERNAME and FPTN_PASSWORD
        if let user = env["FPTN_USERNAME"], let pass = env["FPTN_PASSWORD"] {
            return Credentials(username: user, password: pass)
        }
        
        // 3. Fallback to interactive stdin prompts
        guard isatty(STDIN_FILENO) != 0 else {
            return nil
        }
        
        print("Please enter FPTN Username: ", terminator: "")
        guard let username = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return nil
        }
        
        // Use standard getpass to read password securely without echo
        guard let passCPtr = getpass("Please enter FPTN Password: "),
              let password = String(validatingUTF8: passCPtr) else {
            return nil
        }
        
        return Credentials(username: username, password: password)
    }
    
    public static func parseToken(_ token: String) -> Credentials? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBrotli = trimmed.lowercased().hasPrefix("fptnb:")
        let prefix = isBrotli ? "fptnb:" : "fptn:"
        
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let cleaned = trimmed.dropFirst(prefix.count)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        
        let remainder = cleaned.count % 4
        let padded = remainder > 0 ? cleaned + String(repeating: "=", count: 4 - remainder) : cleaned
        
        guard let decoded = Data(base64Encoded: padded) else { return nil }
        
        let jsonData: Data
        if isBrotli {
            guard let decompressed = decompressBrotli(decoded) else { return nil }
            jsonData = decompressed
        } else {
            jsonData = decoded
        }
        
        let decoder = JSONDecoder()
        guard let parsed = try? decoder.decode(FPTNToken.self, from: jsonData) else { return nil }
        return Credentials(username: parsed.username, password: parsed.password)
    }
    
    private static func decompressBrotli(_ compressed: Data) -> Data? {
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
        
        guard written > 0 else { return nil }
        return Data(output[..<written])
    }
}

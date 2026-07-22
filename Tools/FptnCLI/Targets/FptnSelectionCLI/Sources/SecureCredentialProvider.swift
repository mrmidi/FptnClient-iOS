/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Darwin
import FptnSharedCore
import Compression

public struct SecureCredentialProvider {
    public static func getCredentials(args: [String] = CommandLine.arguments) -> Credentials? {
        // 1. Try command-line --token flag (e.g., --token <val> or --token=<val>)
        if let tokenStr = getCLIArgValue(for: "--token", args: args) {
            if let creds = parseToken(tokenStr) {
                return creds
            }
        }

        // 2. Try command-line --username and --password flags
        if let user = getCLIArgValue(for: "--username", args: args),
           let pass = getCLIArgValue(for: "--password", args: args) {
            return Credentials(username: user, password: pass)
        }

        let env = ProcessInfo.processInfo.environment

        // 3. Try FPTN_TOKEN env var
        if let tokenStr = env["FPTN_TOKEN"] {
            if let creds = parseToken(tokenStr) {
                return creds
            }
        }

        // 4. Try FPTN_USERNAME and FPTN_PASSWORD env vars
        if let user = env["FPTN_USERNAME"], let pass = env["FPTN_PASSWORD"] {
            return Credentials(username: user, password: pass)
        }

        // 5. Fallback to interactive stdin prompts
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

    private static func getCLIArgValue(for flag: String, args: [String]) -> String? {
        let prefix = "\(flag)="
        for arg in args {
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
            }
        }
        if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
            return args[idx + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
        }
        return nil
    }
    
    public static func parseFPTNToken(_ token: String) -> FPTNToken? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'")).trimmingCharacters(in: .whitespacesAndNewlines)
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
        do {
            return try decoder.decode(FPTNToken.self, from: jsonData)
        } catch {
            print("Token JSON decode error: \(error)")
            return nil
        }
    }

    public static func parseToken(_ token: String) -> Credentials? {
        guard let parsed = parseFPTNToken(token) else { return nil }
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

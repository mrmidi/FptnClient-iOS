/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

public struct JSONLOutputRecord<T: Codable>: Codable {
    public let timestamp: String
    public let gitCommit: String
    public let architecture: String
    public let os: String
    public let command: String
    public let data: T
}

public struct JSONLOutput {
    public static func printRecord<T: Codable>(command: String, data: T, toFile: String? = nil) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        
        let record = JSONLOutputRecord(
            timestamp: timestamp,
            gitCommit: BuildInfo.gitCommitID,
            architecture: arch,
            os: osVersion,
            command: command,
            data: data
        )
        
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(record),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        // Print JSONL to standard output
        print(jsonString)
        
        // Append to file if requested
        if let path = toFile {
            let fileURL = URL(fileURLWithPath: path)
            let line = jsonString + "\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                        defer { try? fileHandle.close() }
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                    }
                } else {
                    try? data.write(to: fileURL, options: [.atomic])
                }
            }
        }
    }
}

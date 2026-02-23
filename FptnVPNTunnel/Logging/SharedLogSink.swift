/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

// MARK: - Shared log sink (App Group file)

/// Writes log lines to a rolling text file in the shared App Group container.
/// Both the app and the tunnel extension write to the same file.
///
/// Group: group.net.mrmidi.FptnVPN
/// File:  logs/fptn.log
/// Max lines: 1000
final class SharedLogSink: @unchecked Sendable {

    static let shared = SharedLogSink()

    private let appGroup = "group.net.mrmidi.FptnVPN"
    private let maxLines = 1000
    private let queue = DispatchQueue(label: "org.fptn.logsink", qos: .utility)
    private var fileURL: URL?

    private init() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return
        }
        let logsDir = container.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )
        fileURL = logsDir.appendingPathComponent("fptn.log")
    }

    func write(_ line: String) {
        guard let url = fileURL else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let timestamped = "\(iso8601()) \(line)\n"
            guard let data = timestamped.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forUpdating: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                    self.trimIfNeeded(url: url)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func readAll() -> String {
        guard let url = fileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }

    func clear() {
        guard let url = fileURL else { return }
        queue.async {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func trimIfNeeded(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = contents.components(separatedBy: "\n")
        guard lines.count > maxLines else { return }
        lines = Array(lines.suffix(maxLines))
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private func iso8601() -> String {
    ISO8601DateFormatter().string(from: Date())
}

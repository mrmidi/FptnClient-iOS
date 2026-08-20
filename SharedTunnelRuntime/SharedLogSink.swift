/*=============================================================================
Copyright (c) 2024-2026 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

/// Unified log sink that writes log lines to a rolling file in the shared App Group container.
/// Supports separate targets (app and tunnel) to avoid process lock contention.
final class SharedLogSink: @unchecked Sendable {

    static let app = SharedLogSink(fileName: "app.log")
    static let tunnel = SharedLogSink(fileName: "tunnel.log")

    private let maxFileSize: UInt64 = 512 * 1024 // 512 KB
    private let queue: DispatchQueue
    private var fileURL: URL?

    init(fileName: String) {
        self.queue = DispatchQueue(label: "org.fptn.logsink.\(fileName)", qos: .utility)
        guard let container = FptnAppGroup.containerURL else {
            return
        }
        let logsDir = container.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )
        fileURL = logsDir.appendingPathComponent(fileName)
    }

    /// Asynchronously writes a log line to the file.
    func write(_ line: String) {
        guard let url = fileURL else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let timestamped = "\(self.iso8601()) \(line)\n"
            guard let data = timestamped.data(using: .utf8) else { return }

            let fm = FileManager.default
            
            // Check if rotation is needed before appending
            if fm.fileExists(atPath: url.path) {
                if let attributes = try? fm.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? UInt64,
                   size >= self.maxFileSize {
                    self.rotate(url: url)
                }
            }

            // Append to file (creates file if it doesn't exist)
            if fm.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } catch {
                        // Fail silently in release
                    }
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Synchronously reads new bytes appended to the log file since the given offset.
    /// Automatically handles file rotations/truncations by resetting offset to 0.
    func readNewBytes(from offset: UInt64) -> (data: Data, nextOffset: UInt64)? {
        guard let url = fileURL else { return nil }
        return queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else {
                return (Data(), 0)
            }

            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let fileSize = attributes[.size] as? UInt64 else {
                return nil
            }

            // If file was rotated or truncated, reset offset to 0
            let actualOffset = offset > fileSize ? 0 : offset

            guard fileSize > actualOffset else {
                return (Data(), actualOffset)
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return nil
            }
            defer { try? handle.close() }

            do {
                try handle.seek(toOffset: actualOffset)
                // Read from current offset to end
                let data = try handle.readToEnd() ?? Data()
                return (data, fileSize)
            } catch {
                return nil
            }
        }
    }

    /// Synchronously clears the active and backup log files.
    func clear() {
        guard let url = fileURL else { return }
        queue.sync {
            let fm = FileManager.default
            let backupURL = url.deletingPathExtension().appendingPathExtension("old.log")
            
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: backupURL)
        }
    }

    // MARK: - Private

    private func rotate(url: URL) {
        let fm = FileManager.default
        let backupURL = url.deletingPathExtension().appendingPathExtension("old.log")
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: url, to: backupURL)
    }

    private func iso8601() -> String {
        return ISO8601DateFormatter().string(from: Date())
    }
}

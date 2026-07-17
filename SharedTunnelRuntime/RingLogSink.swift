/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
============================================================================*/

import Foundation

/// Ring-buffer-backed log sink with background disk flush.
///
/// The hot path (`write`) only appends to an in-memory ring buffer —
/// zero IO, zero allocation, minimal lock hold time. A background timer
/// periodically flushes new bytes to the shared file sink.
///
/// Compatible with `SharedLogSink`'s file-based reading API used by
/// `LogsViewModel`.
final class RingLogSink: @unchecked Sendable {

    static let app = RingLogSink(fileName: "app.log")
    static let tunnel = RingLogSink(fileName: "tunnel.log")

    private let buffer: RingLogBuffer
    private let fileSink: SharedLogSink
    private var lastFlushedTail: UInt64 = 0
    private let flushQueue = DispatchQueue(label: "org.fptn.ringlog.flush", qos: .utility)
    private var flushTimer: DispatchSourceTimer?

    private init(fileName: String, capacity: Int = 1_048_576) {
        self.buffer = RingLogBuffer(capacity: capacity)
        self.fileSink = SharedLogSink(fileName: fileName)
        startFlushTimer()
    }

    deinit {
        flushTimer?.cancel()
    }

    /// Hot path: append to ring buffer only. No IO, no allocation.
    func write(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            buffer.append(data)
        }
    }

    /// Forces an immediate flush of all buffered data to disk.
    func flushNow() {
        flushQueue.sync {
            self.performFlush()
        }
    }

    /// Reads new bytes appended to the log file since the given offset.
    /// Delegates to the underlying file sink for compatibility.
    func readNewBytes(from offset: UInt64) -> (data: Data, nextOffset: UInt64)? {
        fileSink.readNewBytes(from: offset)
    }

    /// Clears both the ring buffer and the underlying file.
    func clear() {
        buffer.clear()
        fileSink.clear()
        lastFlushedTail = 0
    }

    // MARK: - Private

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.performFlush()
        }
        timer.resume()
        flushTimer = timer
    }

    private func performFlush() {
        let (newBytes, newTail) = buffer.readSince(lastFlushedTail)
        lastFlushedTail = newTail
        if !newBytes.isEmpty, let text = String(data: newBytes, encoding: .utf8) {
            fileSink.write(text)
        }
    }

    /// Read new bytes for LogsViewModel compatibility.
    /// Ring buffer already flushed to file; just delegate to file sink.

    private static func iso8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

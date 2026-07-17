/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
============================================================================*/

import Foundation

/// Lock-based circular byte buffer for hot-path logging.
///
/// The hot path only acquires the lock for pointer math + memcpy — never
/// for IO, allocation, or dispatch. When the buffer fills, oldest bytes
/// are overwritten.
///
/// Thread-safe for single-producer / single-consumer use. The lock is
/// held for the minimum time necessary.
final class RingLogBuffer: @unchecked Sendable {

    private let capacity: Int
    private var buffer: [UInt8]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0
    private var generation: UInt64 = 0
    private let lock = NSLock()

    init(capacity: Int = 1_048_576) {
        self.capacity = capacity
        self.buffer = [UInt8](repeating: 0, count: capacity)
    }

    /// Appends bytes to the buffer. If the buffer is full, overwrites
    /// the oldest data. Never blocks, never allocates on the hot path.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let bytes = [UInt8](data)
        var written = 0

        while written < bytes.count {
            let space = capacity - count
            if space == 0 {
                advanceTailPastNewline()
            }
            let toWrite = min(bytes.count - written, capacity - count)
            let end = min(head + toWrite, capacity)
            let chunk = end - head
            (0..<chunk).forEach { i in
                buffer[head + i] = bytes[written + i]
            }
            written += chunk
            head = (head + chunk) % capacity
            count += chunk
        }
        generation &+= 1
    }

    /// Returns all bytes written since the given tail position, plus
    /// the new tail. Handles wrap-around and overwrites.
    func readSince(_ requestedTail: UInt64) -> (data: Data, tail: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let currentGen = generation
        if requestedTail >= currentGen {
            return (Data(), currentGen)
        }

        if count == 0 {
            return (Data(), currentGen)
        }

        var result = [UInt8]()
        result.reserveCapacity(count)
        var pos = tail
        var remaining = count
        while remaining > 0 {
            let chunkEnd = min(pos + remaining, capacity)
            result.append(contentsOf: buffer[pos..<chunkEnd])
            remaining -= (chunkEnd - pos)
            pos = 0
        }
        return (Data(result), currentGen)
    }

    /// Clears all data in the buffer.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        tail = 0
        count = 0
        generation &+= 1
    }

    // MARK: - Private

    private func advanceTailPastNewline() {
        var pos = tail
        var scanned = 0
        while scanned < count {
            let byte = buffer[pos]
            scanned += 1
            pos = (pos + 1) % capacity
            if byte == 0x0A { // '\n'
                break
            }
        }
        tail = pos
        count -= scanned
    }
}

/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
============================================================================*/

import Foundation
import Network

/// Monitors network path availability using NWPathMonitor.
///
/// Used by VPNService to wait for a valid network before attempting
/// connection/reconnect instead of burning retries.
final class NetworkMonitor: @unchecked Sendable {

    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.fptn.networkmonitor", qos: .utility)
    private let lock = NSLock()

    private var _isConnected = false
    private var _isExpensive = false
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpensive
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Waits until a network path is available or the timeout fires.
    /// Returns immediately if already connected.
    func waitForConnectivity(timeout: TimeInterval = 30) async throws {
        if isConnected { return }

        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if _isConnected {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations[id] = continuation
            lock.unlock()

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                lock.lock()
                if let cont = self.continuations.removeValue(forKey: id) {
                    lock.unlock()
                    cont.resume(throwing: NetworkMonitorError.timeout)
                    return
                }
                lock.unlock()
            }
        }
    }

    // MARK: - Private

    private func handlePathUpdate(_ path: NWPath) {
        let connected = path.status == .satisfied
        let expensive = path.isExpensive

        lock.lock()
        let wasConnected = _isConnected
        _isConnected = connected
        _isExpensive = expensive
        let pending = continuations
        continuations.removeAll()
        lock.unlock()

        if connected && !wasConnected {
            logger.info("Network path available (expensive=\(expensive)")
        } else if !connected && wasConnected {
            logger.warning("Network path lost")
        }

        for (_, cont) in pending {
            cont.resume()
        }
    }
}

enum NetworkMonitorError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout: return "Timed out waiting for network connectivity"
        }
    }
}

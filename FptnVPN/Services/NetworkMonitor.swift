/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
============================================================================*/

import Foundation
import Network
import FptnSharedTunnel

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

    private let classifier = NetworkPathEpisodeClassifier(scope: .app)
    
    private var pendingOutageTask: Task<Void, Never>?

    private func handlePathUpdate(_ path: NWPath) {
        let obs = NetworkPathObservation(
            satisfied: path.status == .satisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )

        let (effect, scope) = classifier.handleUpdate(obs, now: ContinuousClock().now)

        lock.lock()
        _isConnected = obs.satisfied
        _isExpensive = obs.expensive
        let pending = continuations
        continuations.removeAll()
        lock.unlock()

        switch effect {
        case .transitionRecorded(let observation):
            pendingOutageTask?.cancel()
            pendingOutageTask = nil
            logger.info("Network path available [scope=\(scope.rawValue) expensive=\(observation.expensive)]")
        case .scheduleConfirmation(let episodeID, _):
            pendingOutageTask?.cancel()
            pendingOutageTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let (timerEffect, timerScope) = self.classifier.evaluateConfirmationTimer(episodeID: episodeID, now: ContinuousClock().now)
                if timerEffect == .confirmedOutage(episodeID: episodeID) {
                    logger.warning("Default network path remained unsatisfied after 2.0s [scope=\(timerScope.rawValue) classification=confirmedOutage]")
                }
            }
        case .recovered(let classification, let duration):
            pendingOutageTask?.cancel()
            pendingOutageTask = nil
            let durMs = Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            logger.info("Default network path recovered after \(durMs)ms [scope=\(scope.rawValue) classification=\(classification.rawValue)]")
        case .duplicateIgnored, .cancelConfirmation, .confirmedOutage:
            break
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

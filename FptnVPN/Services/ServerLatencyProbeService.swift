/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Network

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    /// Returns `true` on the first call; `false` on subsequent calls.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _value { return false }
        _value = true
        return true
    }
}

private actor ServerProbeWorkQueue {
    private var items: [VPNServer]

    init(items: [VPNServer]) {
        self.items = items
    }

    func next() -> VPNServer? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

struct ServerLatencyProbeConfig: Sendable {
    let timeoutMs: Int
    let concurrency: Int

    static let `default` = ServerLatencyProbeConfig(timeoutMs: 1500, concurrency: 6)
}

actor ServerLatencyProbeService {
    func runProbe(
        servers: [VPNServer],
        config: ServerLatencyProbeConfig = .default
    ) -> AsyncStream<ServerLatencyEvent> {
        AsyncStream { continuation in
            Task {
                guard !servers.isEmpty else {
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                }

                let queue = ServerProbeWorkQueue(items: servers)
                let semaphore = AsyncSemaphore(permits: max(1, min(config.concurrency, servers.count)))

                var done = 0
                var reachable = 0
                var timeout = 0
                var unreachable = 0
                var best: ServerLatencyProbeResult?

                await withTaskGroup(of: ServerLatencyProbeResult?.self) { group in
                    let workerCount = max(1, min(config.concurrency, servers.count))

                    for _ in 0..<workerCount {
                        group.addTask {
                            guard let server = await queue.next() else { return nil }
                            guard !Task.isCancelled else { return nil }
                            await semaphore.acquire()
                            let result = await Self.probe(server: server, timeoutMs: config.timeoutMs)
                            await semaphore.release()
                            return result
                        }
                    }

                    for await maybeResult in group {
                        guard let result = maybeResult else { continue }
                        if Task.isCancelled { break }

                        done += 1
                        switch result.state {
                        case .reachable:
                            reachable += 1
                            if best == nil || (result.latencyMs ?? Int.max) < (best?.latencyMs ?? Int.max) {
                                best = result
                            }
                        case .timeout:
                            timeout += 1
                        case .unreachable:
                            unreachable += 1
                        }

                        continuation.yield(.result(result))
                        continuation.yield(.progress(ServerLatencyProgress(
                            done: done,
                            total: servers.count,
                            reachable: reachable,
                            timeout: timeout,
                            unreachable: unreachable,
                            best: best
                        )))

                        group.addTask {
                            guard let server = await queue.next() else { return nil }
                            guard !Task.isCancelled else { return nil }
                            await semaphore.acquire()
                            let result = await Self.probe(server: server, timeoutMs: config.timeoutMs)
                            await semaphore.release()
                            return result
                        }
                    }
                }

                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    func collectAll(
        servers: [VPNServer],
        config: ServerLatencyProbeConfig = .default
    ) async -> [ServerLatencyProbeResult] {
        let stream = runProbe(servers: servers, config: config)
        var results: [ServerLatencyProbeResult] = []
        for await event in stream {
            if case .result(let result) = event {
                results.append(result)
            }
        }
        return results
    }

    private static func probe(server: VPNServer, timeoutMs: Int) async -> ServerLatencyProbeResult {
        guard let port = NWEndpoint.Port(rawValue: UInt16(server.port)) else {
            return ServerLatencyProbeResult(
                server: server,
                state: .unreachable,
                latencyMs: nil,
                detail: "invalid_port",
                checkedAt: Date().timeIntervalSince1970
            )
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp)
            let queue = DispatchQueue(label: "org.fptn.server-probe.\(server.id)")
            let clock = ContinuousClock()
            let start = clock.now
            let finishedFlag = AtomicFlag()

            @Sendable func finish(state: ServerLatencyState, latencyMs: Int?, detail: String) {
                guard finishedFlag.testAndSet() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: ServerLatencyProbeResult(
                    server: server,
                    state: state,
                    latencyMs: latencyMs,
                    detail: detail,
                    checkedAt: Date().timeIntervalSince1970
                ))
            }

            let timeoutItem = DispatchWorkItem {
                finish(state: .timeout, latencyMs: nil, detail: "timeout")
            }
            nonisolated(unsafe) let timeoutRef = timeoutItem

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutRef.cancel()
                    let duration = clock.now - start
                    let elapsedMs = Int(
                        Double(duration.components.seconds) * 1000
                        + Double(duration.components.attoseconds) / 1e15
                    )
                    finish(state: .reachable, latencyMs: elapsedMs, detail: "connected")
                case .failed(let error):
                    timeoutRef.cancel()
                    let detail = describe(error: error)
                    let resultState = classify(error: error)
                    finish(state: resultState, latencyMs: nil, detail: detail)
                case .cancelled:
                    timeoutRef.cancel()
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeoutItem)
            connection.start(queue: queue)
        }
    }

    private static func classify(error: NWError) -> ServerLatencyState {
        switch error {
        case .posix(let code) where code == .ETIMEDOUT:
            return .timeout
        default:
            return .unreachable
        }
    }

    private static func describe(error: NWError) -> String {
        switch error {
        case .posix(let code):
            return code.rawValue == POSIXErrorCode.ETIMEDOUT.rawValue ? "timeout" : "posix_\(code.rawValue)"
        case .dns(let code):
            return "dns_\(code)"
        case .tls(let osStatus):
            return "tls_\(osStatus)"
        case .wifiAware(let code):
            return "wifiaware_\(code)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

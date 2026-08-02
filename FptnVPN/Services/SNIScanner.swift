/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

// MARK: - AsyncSemaphore

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}

// MARK: - WorkQueue

actor WorkQueue {
    private var items: [String]

    init(items: [String]) {
        self.items = items
    }

    func next() -> String? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

// MARK: - Prober

final class Prober: Sendable {
    func probe(sni: String, cfg: ProbeConfig) async -> ProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        let timeoutSeconds = max(1, Int(ceil(Double(cfg.timeoutMs) / 1000.0)))
        let client = ApiClientBridge(
            host: cfg.server.host,
            port: cfg.server.port,
            sni: sni,
            md5Fingerprint: cfg.server.md5_fingerprint,
            censorshipStrategy: cfg.bypassMethod.rawValue
        )

        let handshake = await client.testHandshake(timeout: timeoutSeconds)
        guard handshake.reachable else {
            return ProbeResult(
                sni: sni,
                strategyRawValue: cfg.bypassMethod.rawValue,
                status: .unreachable,
                latencyMs: -1,
                handshakeLatencyMs: handshake.latencyMs,
                httpCode: nil,
                detail: handshake.error ?? "Handshake failed",
                ts: Date().timeIntervalSince1970
            )
        }

        let response = await client.get(path: "/api/v1/test/file.bin", timeout: timeoutSeconds)
        let duration = clock.now - start
        let elapsed = Int(
            Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        )

        if let error = response.error, !error.isEmpty {
            return ProbeResult(
                sni: sni,
                strategyRawValue: cfg.bypassMethod.rawValue,
                status: .unreachable,
                latencyMs: elapsed,
                handshakeLatencyMs: handshake.latencyMs,
                httpCode: response.code,
                detail: error,
                ts: Date().timeIntervalSince1970
            )
        }

        guard response.code == 200 else {
            return ProbeResult(
                sni: sni,
                strategyRawValue: cfg.bypassMethod.rawValue,
                status: .unreachable,
                latencyMs: elapsed,
                handshakeLatencyMs: handshake.latencyMs,
                httpCode: response.code,
                detail: "HTTP \(response.code)",
                ts: Date().timeIntervalSince1970
            )
        }

        return ProbeResult(
            sni: sni,
            strategyRawValue: cfg.bypassMethod.rawValue,
            status: .reachable,
            latencyMs: elapsed,
            handshakeLatencyMs: handshake.latencyMs,
            httpCode: response.code,
            detail: "Handshake \(handshake.latencyMs.map { "\($0)ms" } ?? "ok"), HTTP \(response.code)",
            ts: Date().timeIntervalSince1970
        )
    }
}

// MARK: - ScannerEngine

actor ScannerEngine {
    func runScan(snis: [String], cfg: ProbeConfig) -> AsyncStream<ScanEvent> {
        let dedupedSNIs = Self.deduplicate(snis)
        let total = dedupedSNIs.count

        return AsyncStream { continuation in
            Task {
                guard !dedupedSNIs.isEmpty else {
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                }

                let workQueue = WorkQueue(items: dedupedSNIs)
                let semaphore = AsyncSemaphore(permits: cfg.concurrency)
                let prober = Prober()

                var done = 0
                var reachable = 0
                var unreachable = 0
                var best: ProbeResult?

                await withTaskGroup(of: ProbeResult?.self) { group in
                    let workerCount = min(cfg.concurrency, dedupedSNIs.count)
                    for _ in 0..<workerCount {
                        group.addTask {
                            guard let sni = await workQueue.next() else { return nil }
                            if Task.isCancelled { return nil }
                            await semaphore.acquire()
                            let result = await prober.probe(sni: sni, cfg: cfg)
                            await semaphore.release()
                            return result
                        }
                    }

                    for await maybeResult in group {
                        guard let result = maybeResult else { continue }
                        if Task.isCancelled { break }

                        done += 1
                        switch result.status {
                        case .reachable:
                            reachable += 1
                            if best == nil || result.latencyMs < best!.latencyMs {
                                best = result
                            }
                        case .unreachable:
                            unreachable += 1
                        }

                        continuation.yield(.result(result))
                        continuation.yield(.progress(ScanProgress(
                            done: done,
                            total: total,
                            reachable: reachable,
                            unreachable: unreachable,
                            best: best
                        )))

                        group.addTask {
                            guard let sni = await workQueue.next() else { return nil }
                            if Task.isCancelled { return nil }
                            await semaphore.acquire()
                            let r = await prober.probe(sni: sni, cfg: cfg)
                            await semaphore.release()
                            return r
                        }
                    }
                }

                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    // MARK: - Sanitization (also called from ViewModel)

    static func sanitize(_ input: String) -> [String] {
        deduplicate(
            input
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                    // Strip scheme, www prefix, and paths — mirrors the Java version's pre-processing
                    let clean = SettingsService.sanitizeSNI(trimmed)
                    guard !clean.isEmpty, isValidDomain(clean) else { return nil }
                    return clean
                }
        )
    }

    // MARK: - Domain validation

    // Matches optional wildcard prefix (*.),  one or more dot-separated labels,
    // and a TLD of at least 2 alpha characters.
    // Examples: example.com, sub.example.com, *.example.co.uk
    private static let domainRegex: NSRegularExpression = {
        let pattern = #"^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"#
        // Force-unwrap is safe: the pattern is a compile-time constant.
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func isValidDomain(_ host: String) -> Bool {
        let range = NSRange(host.startIndex..., in: host)
        return domainRegex.firstMatch(in: host, range: range) != nil
    }

    private static func deduplicate(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

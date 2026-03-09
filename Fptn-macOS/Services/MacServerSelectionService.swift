import Foundation
import FptnSharedCore
import Combine
import Network

@MainActor
final class MacServerSelectionService: ObservableObject {
    @Published private(set) var isMeasuring = false
    @Published private(set) var lastSelectionSummary: String = ""

    func selectBestServer(from servers: [MacVPNServer], timeoutMs: Int = 1200) async -> MacVPNServer? {
        guard !servers.isEmpty else { return nil }
        isMeasuring = true
        defer { isMeasuring = false }

        var best: (server: MacVPNServer, latency: Double)?

        await withTaskGroup(of: (MacVPNServer, Double?).self) { group in
            for server in servers {
                group.addTask {
                    let latency = await Self.measureTCPConnectLatency(host: server.host, port: server.port, timeoutMs: timeoutMs)
                    return (server, latency)
                }
            }

            for await (server, latency) in group {
                guard let latency else { continue }
                if best == nil || latency < best!.latency {
                    best = (server, latency)
                }
            }
        }

        if let best {
            lastSelectionSummary = "Smart Connect picked \(best.server.name) in \(Int(best.latency)) ms"
            return best.server
        }

        lastSelectionSummary = "Smart Connect fallback: first server"
        return servers.first
    }

    nonisolated private static func measureTCPConnectLatency(host: String, port: Int, timeoutMs: Int) async -> Double? {
        await withCheckedContinuation { continuation in
            let start = CFAbsoluteTimeGetCurrent()
            let queue = DispatchQueue(label: "fptn.macos.smartconnect")
            let endpoint = NWEndpoint.Host(host)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: nil)
                return
            }

            let conn = NWConnection(host: endpoint, port: nwPort, using: .tcp)
            let lock = NSLock()
            // Use a class box so the @Sendable closures can share mutable state safely
            final class FinishState: @unchecked Sendable {
                var finished = false
            }
            let state = FinishState()

            let finish: @Sendable (Double?) -> Void = { value in
                lock.lock()
                defer { lock.unlock() }
                guard !state.finished else { return }
                state.finished = true
                conn.cancel()
                continuation.resume(returning: value)
            }

            conn.stateUpdateHandler = { nwState in
                switch nwState {
                case .ready:
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    finish(elapsed)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                finish(nil)
            }
        }
    }
}

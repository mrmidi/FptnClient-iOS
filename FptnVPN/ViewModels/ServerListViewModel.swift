/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

@MainActor
final class ServerListViewModel: ObservableObject {
    struct ServerProgress: Sendable {
        let done: Int
        let total: Int
    }

    @Published private(set) var rows: [ServerListRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress: ServerProgress? = nil

    private let tokenService: TokenService
    private let scanner: SlidingWindowPingScanner
    private let latencyCache: ServerLatencyCache

    init(
        tokenService: TokenService = .shared,
        scanner: SlidingWindowPingScanner = SlidingWindowPingScanner(),
        latencyCache: ServerLatencyCache = .shared
    ) {
        self.tokenService = tokenService
        self.scanner = scanner
        self.latencyCache = latencyCache
    }

    func loadServers() async {
        let servers = await tokenService.getServers()
        let cached = latencyCache.latencies
        rows = ServerListRow.sorted(
            servers.map { ServerListRow(server: $0, latency: cached[$0.id]) }
        )
        logger.debug("ServerListViewModel loaded \(rows.count) server rows with \(cached.count) cached latencies")
    }

    func refreshServers() async {
        isRefreshing = true
        progress = nil
        let servers = await tokenService.getServers()
        var liveLatencies: [String: ServerLatencyRecord] = latencyCache.latencies

        rows = ServerListRow.sorted(
            servers.map { ServerListRow(server: $0, latency: liveLatencies[$0.id]) }
        )

        for await pingResult in scanner.scan(servers: servers, maxActive: 6, pingHandler: { server in
            let bridge = ApiClientBridge(
                host: server.host,
                port: server.port,
                sni: server.host,
                md5Fingerprint: server.md5Fingerprint,
                censorshipStrategy: "SNI",
                name: server.name
            )
            let res = await bridge.testHandshake(timeout: 3)
            return ServerPingResult(
                serverID: server.id,
                isReachable: res.reachable,
                latencyMs: res.latencyMs
            )
        }) {
            let record = ServerLatencyRecord(
                serverID: pingResult.serverID,
                state: pingResult.isReachable ? .reachable : .unreachable,
                latencyMs: pingResult.latencyMs,
                detail: pingResult.isReachable ? "\(pingResult.latencyMs ?? 0) ms" : "unreachable",
                checkedAt: Date().timeIntervalSince1970
            )
            liveLatencies[pingResult.serverID] = record
            latencyCache.update(record: record)
            rows = ServerListRow.sorted(
                servers.map { server in
                    ServerListRow(server: server, latency: liveLatencies[server.id])
                }
            )
        }

        isRefreshing = false
    }

    var autoSummaryText: String {
        if let best = rows.first(where: { $0.isReachable }) {
            return best.latencyText
        }
        return "Auto"
    }
}

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
    private let healthStore: any ServerHealthStore

    init(
        tokenService: TokenService = .shared,
        scanner: SlidingWindowPingScanner = SlidingWindowPingScanner(),
        latencyCache: ServerLatencyCache = .shared,
        healthStore: any ServerHealthStore = ServerHealthContext.makeStore()
    ) {
        self.tokenService = tokenService
        self.scanner = scanner
        self.latencyCache = latencyCache
        self.healthStore = healthStore
    }

    func loadServers() async {
        let servers = await tokenService.getServers()
        let stored = await storedLatencies(for: servers)
        rows = ServerListRow.sorted(
            servers.map { ServerListRow(server: $0, latency: stored[$0.id]) }
        )
        logger.debug("ServerListViewModel loaded \(rows.count) server rows with \(stored.count) stored latencies")
    }

    /// Baseline from the persisted health store — which the connect-time
    /// auto-select scan writes — overlaid with any fresher handshake probes
    /// from a pull-to-refresh on this screen.
    ///
    /// The two are deliberately kept apart: the health store's EWMA measures a
    /// full bootstrap (login + DNS) and drives auto-selection, so feeding
    /// handshake-only probe timings into it would skew server choice.
    private func storedLatencies(for servers: [VPNServer]) async -> [String: ServerLatencyRecord] {
        var merged = await healthLatencies(for: servers)
        for (serverID, probed) in latencyCache.latencies {
            merged[serverID] = probed
        }
        return merged
    }

    private func healthLatencies(for servers: [VPNServer]) async -> [String: ServerLatencyRecord] {
        guard !servers.isEmpty, let token = await tokenService.getTokenData() else { return [:] }

        let context = ServerHealthContext.makeContext(
            tokenUsername: token.username,
            servers: servers,
            settings: SettingsService.shared
        )
        let keys = ServerHealthContext.keys(for: servers, context: context)

        do {
            let records = try await healthStore.load(for: keys)
            return records.values.reduce(into: [:]) { result, record in
                if let latency = ServerLatencyRecord(health: record) {
                    result[record.key.serverID] = latency
                }
            }
        } catch {
            logger.warning("ServerListViewModel failed to load server health: \(error)")
            return [:]
        }
    }

    func refreshServers() async {
        isRefreshing = true
        progress = nil
        let servers = await tokenService.getServers()
        var liveLatencies = await storedLatencies(for: servers)

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

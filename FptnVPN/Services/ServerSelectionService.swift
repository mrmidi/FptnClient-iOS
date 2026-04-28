/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

actor ServerSelectionService {
    static let shared = ServerSelectionService()

    private let tokenService = TokenService.shared
    private let latencyCache = ServerLatencyCacheService.shared
    private let probeService = ServerLatencyProbeService()

    func getBestServer() async -> VPNServer? {
        let selection = await selectBestReachableServerForAutoMode()
        return selection.selectedServer
    }

    func getAllServers() async -> [VPNServer] {
        return await tokenService.getServers()
    }

    func cachedServerRows() async -> [ServerListRow] {
        let servers = await tokenService.getServers()
        let cache = await latencyCache.freshRecords()
        return composeRows(servers: servers, cache: cache)
    }

    func saveProbeResult(_ result: ServerLatencyProbeResult) async {
        await latencyCache.save(result.cacheRecord)
    }

    func saveProbeResults(_ results: [ServerLatencyProbeResult]) async {
        await latencyCache.save(results)
    }

    func selectBestReachableServerForAutoMode() async -> AutoServerSelection {
        let servers = await tokenService.getServers()
        let cache = await latencyCache.freshRecords()
        let rows = composeRows(servers: servers, cache: cache)
        let best = rows.first(where: { $0.isReachable })?.server
        return AutoServerSelection(selectedServer: best, rows: rows)
    }

    func runLatencyScan(
        config: ServerLatencyProbeConfig = .default
    ) async -> AsyncStream<ServerLatencyEvent> {
        let servers = await tokenService.getServers()
        return await probeService.runProbe(servers: servers, config: config)
    }

    func refreshBestReachableServerForAutoMode(
        config: ServerLatencyProbeConfig = .default
    ) async -> AutoServerSelection {
        let servers = await tokenService.getServers()
        let results = await probeService.collectAll(servers: servers, config: config)
        await latencyCache.save(results)
        var records = Dictionary(uniqueKeysWithValues: results.map { ($0.server.id, $0.cacheRecord) })
        let tcpRows = composeRows(
            servers: servers,
            cache: records
        )
        if let bestTcpServer = tcpRows.first(where: { $0.isReachable })?.server {
            let verified = verifyServerForCurrentStrategy(bestTcpServer)
            records[bestTcpServer.id] = verified.cacheRecord
            await latencyCache.save(verified.cacheRecord)
        }
        let rows = composeRows(servers: servers, cache: records)
        let best = rows.first(where: { $0.isReachable })?.server
        return AutoServerSelection(selectedServer: best, rows: rows)
    }

    func cachedWarningMessage() async -> String? {
        warningMessage(for: await cachedServerRows())
    }

    func warningMessage(for rows: [ServerListRow]) -> String? {
        let reachable = rows.filter { $0.isReachable }
        guard !reachable.isEmpty else { return nil }
        guard reachable.allSatisfy({ Self.isRussiaNamedServer($0.server.name) }) else { return nil }
        return "Only Russia-based servers appear reachable right now. This may indicate local network filtering."
    }

    private func composeRows(servers: [VPNServer], cache: [String: ServerLatencyRecord]) -> [ServerListRow] {
        ServerListRow.sorted(
            servers.map { server in
                ServerListRow(server: server, latency: cache[server.id])
            }
        )
    }

    private nonisolated func verifyServerForCurrentStrategy(_ server: VPNServer) -> ServerLatencyProbeResult {
        let settings = SettingsService.shared
        let strategy = settings.censorshipStrategy
        let timeoutSeconds = 5
        let client = ApiClientBridge(
            host: server.host,
            port: server.port,
            sni: settings.sni,
            md5Fingerprint: server.md5_fingerprint,
            censorshipStrategy: strategy.rawValue
        )

        let handshake = client.testHandshake(timeout: timeoutSeconds)
        guard handshake.reachable else {
            return ServerLatencyProbeResult(
                server: server,
                state: .unreachable,
                latencyMs: handshake.latencyMs,
                detail: "verify_handshake_failed:\(handshake.error ?? "unknown")",
                checkedAt: Date().timeIntervalSince1970
            )
        }

        let dns = client.get(path: "/api/v1/dns", timeout: timeoutSeconds)
        if let error = dns.error, !error.isEmpty {
            return ServerLatencyProbeResult(
                server: server,
                state: .unreachable,
                latencyMs: handshake.latencyMs,
                detail: "verify_dns_failed:\(error)",
                checkedAt: Date().timeIntervalSince1970
            )
        }

        return ServerLatencyProbeResult(
            server: server,
            state: .reachable,
            latencyMs: handshake.latencyMs,
            detail: "verified_http_\(dns.code)",
            checkedAt: Date().timeIntervalSince1970
        )
    }

    private static func isRussiaNamedServer(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("russia") || normalized.contains("россия") || normalized.contains("рос")
    }
}

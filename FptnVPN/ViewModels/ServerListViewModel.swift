/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class ServerListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var rows: [ServerListRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress: ServerLatencyProgress?

    // MARK: - Dependencies

    private let serverSelectionService: ServerSelectionService

    init(serverSelectionService: ServerSelectionService = .shared) {
        self.serverSelectionService = serverSelectionService
    }

    // MARK: - Commands

    func loadServers() async {
        rows = await serverSelectionService.cachedServerRows()
        logger.debug("ServerListViewModel loaded \(rows.count) server rows")
    }

    func refreshServers() async {
        isRefreshing = true
        progress = nil
        let allServers = await serverSelectionService.getAllServers()

        var liveRecords: [String: ServerLatencyRecord] = [:]
        for row in rows {
            if let latency = row.latency {
                liveRecords[row.server.id] = latency
            }
        }

        let stream = await serverSelectionService.runLatencyScan()
        for await event in stream {
            switch event {
            case .result(let result):
                liveRecords[result.server.id] = result.cacheRecord
                await serverSelectionService.saveProbeResult(result)
                rows = ServerListRow.sorted(
                    allServers.map { server in
                        ServerListRow(server: server, latency: liveRecords[server.id])
                    }
                )
            case .progress(let progress):
                self.progress = progress
            case .finished:
                break
            }
        }

        isRefreshing = false
    }

    var autoSummaryText: String {
        if let best = rows.first(where: { $0.isReachable }) {
            return best.latencyText
        }
        if rows.contains(where: { $0.latency != nil }) {
            return "timeout"
        }
        return "--"
    }
}

/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

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

    init(tokenService: TokenService = .shared) {
        self.tokenService = tokenService
    }

    func loadServers() async {
        let servers = await tokenService.getServers()
        rows = servers.map { ServerListRow(server: $0, latency: nil) }
        logger.debug("ServerListViewModel loaded \(rows.count) server rows")
    }

    func refreshServers() async {
        isRefreshing = true
        let servers = await tokenService.getServers()
        rows = servers.map { ServerListRow(server: $0, latency: nil) }
        isRefreshing = false
    }

    var autoSummaryText: String {
        if let best = rows.first(where: { $0.isReachable }) {
            return best.latencyText
        }
        return "Auto"
    }
}

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class ServerListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var servers: [VPNServer] = []

    // MARK: - Dependencies

    private let serverSelectionService: ServerSelectionService

    init(serverSelectionService: ServerSelectionService = .shared) {
        self.serverSelectionService = serverSelectionService
    }

    // MARK: - Commands

    func loadServers() async {
        servers = await serverSelectionService.getAllServers()
        logger.debug("ServerListViewModel loaded \(servers.count) servers")
    }
}

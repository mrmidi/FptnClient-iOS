/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

actor ServerSelectionService {
    static let shared = ServerSelectionService()

    private let tokenService = TokenService.shared

    func getBestServer() async -> VPNServer? {
        let servers = await tokenService.getServers()
        // Simple logic: first server. Future phases will add ping-based selection.
        return servers.first
    }

    func getAllServers() async -> [VPNServer] {
        return await tokenService.getServers()
    }
}

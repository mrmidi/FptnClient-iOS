/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine

@MainActor
final class HomeViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isConnected = false
    @Published private(set) var connectionTimeString = "00:00:00"
    @Published private(set) var downloadSpeedString = "0.0 Kbps"
    @Published private(set) var uploadSpeedString = "0.0 Kbps"
    @Published private(set) var selectedServerName: String? = nil
    @Published private(set) var connectionMode: VPNConnection.ConnectionMode = .auto
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String? = nil

    // MARK: - Dependencies (injected)

    private let vpnService: VPNService

    init(vpnService: VPNService) {
        self.vpnService = vpnService
        observeService()
    }

    // MARK: - Commands

    func syncWithSystem() {
        vpnService.syncWithSystem()
    }

    func connect() {
        vpnService.connect()
    }

    func disconnect() {
        vpnService.disconnect()
    }

    func selectServer(_ server: VPNServer) {
        vpnService.connection.connectionMode = .manual(server)
        syncFromService()
    }

    func setAutoMode() {
        vpnService.connection.connectionMode = .auto
        syncFromService()
    }

    // MARK: - Observation

    private var cancellables = Set<AnyCancellable>()

    private func observeService() {
        vpnService.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFromService()
            }
            .store(in: &cancellables)
    }

    private func syncFromService() {
        let conn = vpnService.connection
        isConnected = conn.isConnected
        selectedServerName = conn.selectedServer?.name
        connectionMode = conn.connectionMode
        connectionTimeString = vpnService.formatConnectionTime()
        downloadSpeedString = vpnService.formatSpeed(conn.downloadSpeed)
        uploadSpeedString = vpnService.formatSpeed(conn.uploadSpeed)
        isConnecting = conn.isConnecting
        errorMessage = conn.errorMessage
    }
}

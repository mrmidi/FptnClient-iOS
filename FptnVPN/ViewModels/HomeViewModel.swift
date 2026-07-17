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
    @Published private(set) var isReconnecting = false
    @Published private(set) var isWaitingForNetwork = false
    @Published private(set) var vpnConflictDetected = false
    @Published private(set) var speedHistory: [SpeedSample] = []
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var warningMessage: String? = nil
    @Published private(set) var runtimeStatusMessage: String? = nil

    // MARK: - Dependencies (injected)

    let vpnService: VPNService

    init(vpnService: VPNService) {
        self.vpnService = vpnService
        observeService()
    }

    // MARK: - Commands

    func syncWithSystem() {
        vpnService.syncWithSystem()
        vpnService.refreshCachedServerWarning()
    }

    func refreshCachedServerWarning() {
        vpnService.refreshCachedServerWarning()
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

        // Repaint the duration label every second. The value is derived from the
        // connection start time, so this only repaints — backgrounding (which
        // pauses this timer) no longer loses elapsed time; it catches up on the
        // next tick and on the scenePhase resync.
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isConnected else { return }
                self.connectionTimeString = self.vpnService.formatConnectionTime()
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
        isReconnecting = conn.isReconnecting
        isWaitingForNetwork = conn.isWaitingForNetwork
        vpnConflictDetected = conn.vpnConflictDetected
        speedHistory = conn.speedHistory
        errorMessage = conn.errorMessage
        warningMessage = conn.warningMessage
        if conn.isReconnecting {
            runtimeStatusMessage = conn.lastTransportError ?? "Waiting for tunnel transport to recover."
        } else if !conn.isConnected {
            runtimeStatusMessage = conn.lastStopReason ?? conn.lastTransportError
        } else {
            runtimeStatusMessage = nil
        }
    }
}

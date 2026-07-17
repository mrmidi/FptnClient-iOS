/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

struct SpeedSample: Sendable {
    let timestamp: Date
    let downloadMbps: Double
    let uploadMbps: Double
}

struct VPNConnection: Sendable {
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var isReconnecting: Bool = false
    var isWaitingForNetwork: Bool = false
    var vpnConflictDetected: Bool = false
    var errorMessage: String? = nil
    var warningMessage: String? = nil
    var runtimeState: TunnelProviderRuntimeState? = nil
    var lastTransportError: String? = nil
    var lastStopReason: String? = nil
    var selectedServer: VPNServer?
    var connectedAt: Date? = nil
    var downloadSpeed: Double = 0
    var uploadSpeed: Double = 0
    var speedHistory: [SpeedSample] = []
    var connectionMode: ConnectionMode = .auto

    enum ConnectionMode: Sendable {
        case auto
        case manual(VPNServer)
    }
}

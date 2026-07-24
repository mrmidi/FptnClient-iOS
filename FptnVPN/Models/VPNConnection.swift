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

    // Exact, provider-reported session traffic (see TunnelTrafficSnapshotV1).
    // Unlike downloadSpeed/uploadSpeed above (derived client-side from
    // consecutive polls), these values come directly from the provider and
    // cover time the app itself was backgrounded and not polling.
    var sessionUploadBytes: UInt64 = 0
    var sessionDownloadBytes: UInt64 = 0
    var peakUploadBytesPerSecond: UInt64 = 0
    var peakDownloadBytesPerSecond: UInt64 = 0
    var peakBandwidthNominalWindowSeconds: UInt32 = 0
    var trafficMetricsSampledAt: UInt64 = 0
    var trafficMetricsAvailable: Bool = false

    var connectionDurationString: String {
        guard let connectedAt else { return "00:00:00" }
        let duration = Int(Date().timeIntervalSince(connectedAt))
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    enum ConnectionMode: Sendable {
        case auto
        case manual(VPNServer)
    }
}

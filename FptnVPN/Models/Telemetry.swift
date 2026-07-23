/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

/// Human-facing connection lifecycle state for the Telemetry screen.
/// Mirrors NEVPNStatus but never surfaces raw numeric status codes to the UI.
enum TelemetryConnectionState: String, CaseIterable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case waitingForNetwork

    var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .waitingForNetwork: return "Waiting for Network"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .appSuccess
        case .connecting, .reconnecting, .waitingForNetwork, .disconnecting: return .appAccent
        case .disconnected: return .appSecondaryText
        }
    }

    var showsActivity: Bool {
        switch self {
        case .connecting, .reconnecting, .disconnecting, .waitingForNetwork: return true
        case .connected, .disconnected: return false
        }
    }
}

/// Freshness of the telemetry feed itself, independent of the tunnel state.
enum TelemetryAvailability: Equatable {
    case live
    case stale(secondsAgo: Int)
    case paused
    case providerStopping
    case unavailable
    case unsupported

    var title: String {
        switch self {
        case .live: return "Live"
        case .stale: return "Stale"
        case .paused: return "Paused"
        case .providerStopping: return "Finalizing Session"
        case .unavailable: return "Telemetry Unavailable"
        case .unsupported: return "Telemetry Unsupported"
        }
    }

    var detail: String {
        switch self {
        case .live: return "Updated just now"
        case .stale(let secondsAgo): return "Last update \(secondsAgo)s ago \u{00B7} tunnel is reconnecting"
        case .paused: return "Live telemetry stops while the app is in the background"
        case .providerStopping: return "The tunnel is shutting down"
        case .unavailable: return "The tunnel provider is not currently reachable"
        case .unsupported: return "Telemetry is unavailable for this tunnel version"
        }
    }

    var tint: Color {
        switch self {
        case .live: return .appSuccess
        case .stale, .paused, .providerStopping: return .appWarning
        case .unavailable, .unsupported: return .appSecondaryText
        }
    }

    /// Whether the banner-level warning card should be shown above the header.
    var needsBanner: Bool {
        switch self {
        case .live: return false
        default: return true
        }
    }
}

enum ThermalLevel: String, CaseIterable {
    case nominal, fair, serious, critical

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }

    var tint: Color {
        switch self {
        case .nominal: return .appSuccess
        case .fair: return .appAccent
        case .serious: return .appWarning
        case .critical: return .appError
        }
    }
}

enum HealthLevel {
    case healthy
    case attention(String)
    case warning(String)
    case critical(String)

    var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .attention(let text), .warning(let text), .critical(let text): return text
        }
    }

    var tint: Color {
        switch self {
        case .healthy: return .appSuccess
        case .attention: return .appAccent
        case .warning: return .appWarning
        case .critical: return .appError
        }
    }
}

struct MemorySample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let physicalMB: Double
}

struct BandwidthSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let downloadMbps: Double
    let uploadMbps: Double
}

struct TelemetryEvent: Identifiable {
    enum Kind {
        case info, success, warning, error

        var tint: Color {
            switch self {
            case .info: return .appSecondaryText
            case .success: return .appSuccess
            case .warning: return .appWarning
            case .error: return .appError
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let message: String
    let kind: Kind
}

enum TelemetryTimeWindow: String, CaseIterable, Identifiable {
    case fiveMinutes, fifteenMinutes, session

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: return "5m"
        case .fifteenMinutes: return "15m"
        case .session: return "Session"
        }
    }

    /// nil means "no lower bound" (full session).
    var duration: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .session: return nil
        }
    }
}

/// One coherent snapshot of everything the Telemetry screen renders.
/// Intentionally flat and Codable-free — this is a UI-facing view model value,
/// not the wire format; wiring it to real IPC data is a separate pass.
struct TelemetrySnapshot {
    // Identity
    var connectionState: TelemetryConnectionState = .connected
    var serverName: String = "France-3"
    var interfaceName: String = "Wi-Fi"
    var connectedDuration: TimeInterval = 0
    var episodeID: String = "1E63775E"
    var generation: Int = 3
    var availability: TelemetryAvailability = .live
    var lastUpdated: Date = .now

    // Memory
    var memoryPhysicalMB: Double = 0
    var memoryResidentMB: Double = 0
    var memoryPeakMB: Double = 0

    // Traffic
    var downloadMbps: Double = 0
    var uploadMbps: Double = 0
    var downloadPeakMbps: Double = 0
    var uploadPeakMbps: Double = 0
    var sessionDownloadBytes: Double = 0
    var sessionUploadBytes: Double = 0

    // Environment
    var thermalState: ThermalLevel = .nominal
    var lowPowerModeEnabled: Bool = false

    // Tunnel health
    var outboundQueueBytes: Int = 0
    var outboundQueuePeakBytes: Int = 0
    var queueFullEvents: Int = 0
    var livePacketLeases: Int = 0
    var peakPacketLeases: Int = 0
    var nativeOperations: Int = 0
    var websocketGeneration: Int = 3
    var healthLevel: HealthLevel = .healthy

    // Network
    var defaultPathAvailable: Bool = true
    var isExpensive: Bool = false
    var isConstrained: Bool = false
    var ipv4Available: Bool = true
    var ipv6Available: Bool = false

    // Recovery
    var reconnectAttempt: Int = 0
    var reconnectCount: Int = 0
    var lastReconnectDate: Date?

    var averageDownloadMbps: Double = 0
    var averageUploadMbps: Double = 0

    static let memoryTargetRange: ClosedRange<Double> = 20...25
    static let memoryWarningMB: Double = 30
    static let memoryCriticalMB: Double = 42
    static let memoryChartCeilingMB: Double = 50
}

enum TelemetryFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    static func megabytes(_ value: Double) -> String {
        String(format: "%.1f MB", value)
    }

    static func mbps(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }

    /// Bytes in, human-scaled MB/GB out.
    static func dataVolume(_ bytes: Double) -> String {
        let mb = bytes / 1_000_000
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }

    static func relativeSeconds(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

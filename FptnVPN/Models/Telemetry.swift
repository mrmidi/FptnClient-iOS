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
        case .paused: return "Live telemetry stops while the app is in the background \u{2014} the tunnel keeps running and counting"
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

/// A sample belongs to a `segmentID`. The chart never draws a line between
/// samples from different segments — the live source was lost and regained
/// between them (backgrounded, or the IPC poll went stale), and drawing a
/// connecting line there would fabricate data for a period nothing observed.
/// A chart sample that can be placed on a time axis. Lets the chart's
/// time-bucketing reduction work over either series without casting.
protocol TimestampedSample: Identifiable {
    var timestamp: Date { get }
    /// Increments whenever the live feed is lost and regained. Samples either
    /// side of a gap belong to different segments and must not be joined by a
    /// line, which would draw an interpolated slope through unmeasured time.
    var segmentID: UInt64 { get }
}

struct MemorySample: TimestampedSample {
    let id = UUID()
    let timestamp: Date
    let physicalMB: Double
    let segmentID: UInt64
}

struct BandwidthSample: TimestampedSample {
    let id = UUID()
    let timestamp: Date
    let downloadMbps: Double
    let uploadMbps: Double
    let segmentID: UInt64
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
    case oneMinute, fiveMinutes, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .all: return "All"
        }
    }

    /// nil means "no lower bound" — everything still held in the bounded
    /// live buffer (see TelemetryViewModel's maximumBandwidthSamples /
    /// maximumMemorySamples caps). This is NOT "the whole tunnel session" —
    /// session totals are a separate, exact, provider-reported number.
    var duration: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .all: return nil
        }
    }
}

/// One coherent snapshot of everything the Telemetry screen renders.
/// Intentionally flat and Codable-free — this is a UI-facing view model value,
/// not the wire format.
///
/// Fields are `Optional` wherever no real value has been observed yet — a
/// field being `nil` renders as "unavailable" in the UI, never as a fake `0`.
/// A concrete `0`/`false`/etc. means "measured, and that's the value."
/// Split-routing counters, shaped for display. Mirrors
/// `TunnelSplitRoutingSnapshotV1` and adds only derived values the view would
/// otherwise recompute on every redraw.
struct SplitRoutingSummary: Equatable {
    /// `active (…)` with rule counts, or `inactive (…)` naming the reason.
    var geoStatus: String

    var directFlows: UInt64
    var fptnFlows: UInt64
    var rejectedFlows: UInt64
    var droppedFlows: UInt64
    var decisions: UInt64
    var activeFlows: UInt64
    var unclassifiableFlows: UInt64

    var packetsToStack: UInt64
    var packetsToTransport: UInt64
    var packetsDropped: UInt64

    var dnsResponsesParsed: UInt64
    var dnsEntries: UInt64

    /// The compiled geo policy is only driving the tunnel when the bridge says
    /// so. Anything else means the fallback policy is deciding.
    var isGeoActive: Bool { geoStatus.hasPrefix("active") }

    /// Share of decided flows that stayed off the tunnel. `nil` before the
    /// first decision, so the view shows "—" rather than a meaningless 0%.
    var directShare: Double? {
        guard decisions > 0 else { return nil }
        return Double(directFlows) / Double(decisions)
    }

    /// The tally must partition `decisions`; a nonzero remainder means a
    /// verdict is going uncounted, which is a bug worth surfacing rather than
    /// hiding behind a percentage that silently stops adding up.
    var untalliedFlows: UInt64 {
        let counted = directFlows + fptnFlows + rejectedFlows + droppedFlows
        return decisions > counted ? decisions - counted : 0
    }
}

struct TelemetrySnapshot {
    // Identity
    var connectionState: TelemetryConnectionState = .disconnected
    var serverName: String?
    /// Not wired in this pass — would need an NWPathMonitor subscription
    /// that doesn't exist yet. Left absent rather than faked.
    var interfaceName: String?
    var connectedDuration: TimeInterval = 0
    /// Hex rendering of the provider's session token. This is a hash derived
    /// from the tunnel's episode identifier, not the episode identifier
    /// itself — it cannot be turned back into anything more meaningful, so it
    /// is labelled as a token, not an "episode ID."
    var sessionTokenHex: String?
    var availability: TelemetryAvailability = .unavailable
    var lastUpdated: Date = .now

    // Memory — sourced from the periodic lifecycle snapshot, nil until the
    // first successful read.
    var memoryPhysicalMB: Double?
    var memoryResidentMB: Double?
    var memoryPeakMB: Double?

    // Traffic — current speed is already real and always defined once
    // connected (0 Mbps is a legitimate measurement, not "unknown"). Session
    // totals and peaks are exact, provider-reported values sourced from the
    // live IPC snapshot; nil until the first one arrives.
    var downloadMbps: Double = 0
    var uploadMbps: Double = 0
    var downloadPeakMbps: Double?
    var uploadPeakMbps: Double?
    var sessionDownloadBytes: UInt64?
    var sessionUploadBytes: UInt64?

    // Environment — read directly from ProcessInfo, no new plumbing needed,
    // so there's no excuse for these to be fake.
    var thermalState: ThermalLevel = .nominal
    var lowPowerModeEnabled: Bool = false

    // Tunnel health — sourced from the periodic lifecycle snapshot, nil until
    // the first successful read.
    var outboundQueueBytes: Int?
    var outboundQueuePeakBytes: Int?
    var queueFullEvents: Int?
    var livePacketLeases: Int?
    var peakPacketLeases: Int?
    var nativeOperations: Int?
    var websocketGeneration: Int?
    var healthLevel: HealthLevel = .healthy

    // Network path — not wired in this pass (would need an NWPathMonitor
    // subscription that doesn't exist yet); left absent rather than faked.
    var defaultPathAvailable: Bool?
    var isExpensive: Bool?
    var isConstrained: Bool?
    var ipv4Available: Bool?
    var ipv6Available: Bool?

    // Split routing — nil unless the split data plane is running, which is the
    // only mode that makes per-flow routing decisions.
    var splitRouting: SplitRoutingSummary?

    // Recovery
    var reconnectAttempt: Int = 0
    var reconnectCount: Int = 0
    var lastReconnectDate: Date?

    static let memoryTargetRange: ClosedRange<Double> = 20...25
    static let memoryWarningMB: Double = Double(TunnelMemoryPressureSnapshot.warningThresholdBytes) / 1_000_000
    static let memoryCriticalMB: Double = Double(TunnelMemoryPressureSnapshot.emergencyThresholdBytes) / 1_000_000
    static let memoryChartCeilingMB: Double = 50
}

enum TelemetryFormat {
    static let unavailable = "\u{2014}"  // em dash

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    static func megabytes(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return String(format: "%.1f MB", value)
    }

    /// Takes Mbps, picks the unit that keeps the value legible. Fixed "%.1f
    /// Mbps" had 0.05 Mbps of resolution, so keepalives, ACKs and DNS — a tunnel
    /// that is quiet but alive — rendered identically to a dead one. Now a
    /// zero reading means actually zero.
    static func bitrate(_ mbps: Double?) -> String {
        guard let mbps else { return unavailable }
        let bitsPerSecond = mbps * 1_000_000
        switch bitsPerSecond {
        case ..<1:
            return "0 bps"
        case ..<1_000:
            return String(format: "%.0f bps", bitsPerSecond)
        case ..<1_000_000:
            return String(format: "%.0f kbps", bitsPerSecond / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1f Mbps", mbps)
        default:
            return String(format: "%.2f Gbps", mbps / 1_000)
        }
    }

    /// Exact byte counts in, adaptively scaled SI units out. The counters are
    /// exact bytes the whole way from the provider (`transportReceivedBytes` ->
    /// `sessionDownloadBytes`), so this is the only place resolution is ever
    /// lost — scale rather than round, so sub-megabyte totals can't read as "0 MB".
    static func dataVolume(_ bytes: UInt64?) -> String {
        guard let bytes else { return unavailable }
        let value = Double(bytes)
        switch value {
        case ..<1_000:
            return "\(bytes) B"
        case ..<1_000_000:
            return String(format: "%.0f kB", value / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1f MB", value / 1_000_000)
        default:
            return String(format: "%.2f GB", value / 1_000_000_000)
        }
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return unavailable }
        return "\(value)"
    }

    static func flag(_ value: Bool?, whenTrue: String, whenFalse: String) -> String {
        guard let value else { return unavailable }
        return value ? whenTrue : whenFalse
    }

    static func relativeSeconds(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

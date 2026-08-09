/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

/// Everything a normal user doesn't need up front: raw counters, network path
/// state, and reconnect bookkeeping. Collapsed by default behind a one-word
/// health summary, plus a short recent-events strip that hands off to Logs.
struct TelemetryHealthView: View {
    @ObservedObject var viewModel: TelemetryViewModel
    @State private var showingLogs = false

    var body: some View {
        VStack(spacing: 12) {
            TunnelHealthSection(snapshot: viewModel.snapshot, isExpanded: $viewModel.isHealthExpanded)
            if let split = viewModel.snapshot.splitRouting {
                SplitRoutingSection(split: split, isExpanded: $viewModel.isSplitRoutingExpanded)
            }
            NetworkSection(snapshot: viewModel.snapshot, isExpanded: $viewModel.isNetworkExpanded)
            RecentEventsSection(events: viewModel.events, onViewAll: { showingLogs = true })
        }
        .sheet(isPresented: $showingLogs) { LogsView() }
    }
}

// MARK: - Tunnel health

private struct TunnelHealthSection: View {
    let snapshot: TelemetrySnapshot
    @Binding var isExpanded: Bool

    var body: some View {
        TelemetrySectionCard(title: "") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    counterRow("Outbound queue", kilobytes(snapshot.outboundQueueBytes))
                    counterRow("Queue peak", kilobytes(snapshot.outboundQueuePeakBytes))
                    counterRow("Queue-full events", TelemetryFormat.count(snapshot.queueFullEvents))
                    counterRow("Live packet leases", TelemetryFormat.count(snapshot.livePacketLeases))
                    counterRow("Peak packet leases", TelemetryFormat.count(snapshot.peakPacketLeases))
                    counterRow("Native operations", TelemetryFormat.count(snapshot.nativeOperations))
                    counterRow("WebSocket generation", TelemetryFormat.count(snapshot.websocketGeneration))
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Text("Tunnel Health")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    StatusPill(label: snapshot.healthLevel.label, tint: snapshot.healthLevel.tint)
                }
            }
            .tint(Color.appAccent)
        }
    }

    private func counterRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appSecondaryText)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    private func kilobytes(_ bytes: Int?) -> String {
        guard let bytes else { return TelemetryFormat.unavailable }
        return "\(bytes / 1000) KB"
    }
}

// MARK: - Split routing

/// Where traffic actually went. The split plane decides a verdict once per
/// flow, and this is the only place those decisions surface: the native
/// per-flow log line was removed because one site opens many flows, and the
/// tunnel extension's native log output does not reliably reach a capture.
private struct SplitRoutingSection: View {
    let split: SplitRoutingSummary
    @Binding var isExpanded: Bool

    var body: some View {
        TelemetrySectionCard(title: "") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    verdictBar

                    VStack(spacing: 8) {
                        counterRow("Direct", count(split.directFlows), tint: .appSuccess)
                        counterRow("Through server", count(split.fptnFlows), tint: .appAccent)
                        counterRow("Rejected", count(split.rejectedFlows), tint: .appWarning)
                        counterRow("Dropped", count(split.droppedFlows), tint: .appError)
                        counterRow("Decided flows", count(split.decisions))
                        if split.untalliedFlows > 0 {
                            // Only ever visible if a verdict stopped being
                            // counted, which is a bug, not a statistic.
                            counterRow("Untallied", count(split.untalliedFlows), tint: .appError)
                        }
                        counterRow("Active flows", count(split.activeFlows))
                        counterRow("Unclassifiable", count(split.unclassifiableFlows))
                    }

                    Divider().background(Color.appSeparator)

                    Text("Geo policy")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                    Text(split.geoStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.appPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().background(Color.appSeparator)

                    Text("Packets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                    VStack(spacing: 8) {
                        counterRow("To local stack", count(split.packetsToStack))
                        counterRow("To server", count(split.packetsToTransport))
                        counterRow("Dropped", count(split.packetsDropped))
                    }

                    Divider().background(Color.appSeparator)

                    Text("Name attribution")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                    VStack(spacing: 8) {
                        counterRow("DNS answers seen", count(split.dnsResponsesParsed))
                        counterRow("Known names", count(split.dnsEntries))
                    }
                    if split.dnsResponsesParsed == 0 {
                        // Without a single answer, no flow can be matched by
                        // name, so every domain rule in the database is inert
                        // and only the address tables are doing any work.
                        Text("No DNS answers observed \u{2014} flows can only be matched by address.")
                            .font(.caption2)
                            .foregroundStyle(Color.appWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Text("Split Routing")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    StatusPill(
                        label: split.isGeoActive ? "Geo active" : "Geo inactive",
                        tint: split.isGeoActive ? .appSuccess : .appWarning
                    )
                }
            }
            .tint(Color.appAccent)
        }
    }

    /// Proportional bar over decided flows. Reads at a glance as "how much of
    /// this session stayed off the tunnel", which no single counter answers.
    private var verdictBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.label) { segment in
                        Rectangle()
                            .fill(segment.tint)
                            .frame(width: max(1, geometry.size.width * segment.share))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .opacity(split.decisions > 0 ? 1 : 0.25)

            HStack {
                Text(split.decisions > 0 ? "\(count(split.directFlows)) of \(count(split.decisions)) flows direct" : "No flows decided yet")
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
                Text(split.directShare.map { "\(Int(($0 * 100).rounded()))%" } ?? TelemetryFormat.unavailable)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.appPrimaryText)
            }
        }
    }

    private struct Segment {
        let label: String
        let tint: Color
        let share: Double
    }

    private var segments: [Segment] {
        let total = Double(split.decisions)
        guard total > 0 else {
            return [Segment(label: "empty", tint: .appSeparator, share: 1)]
        }
        return [
            Segment(label: "direct", tint: .appSuccess, share: Double(split.directFlows) / total),
            Segment(label: "fptn", tint: .appAccent, share: Double(split.fptnFlows) / total),
            Segment(label: "reject", tint: .appWarning, share: Double(split.rejectedFlows) / total),
            Segment(label: "drop", tint: .appError, share: Double(split.droppedFlows) / total),
        ].filter { $0.share > 0 }
    }

    private func count(_ value: UInt64) -> String {
        TelemetryFormat.count(Int(value))
    }

    private func counterRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appSecondaryText)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }
}

// MARK: - Network + recovery

private struct NetworkSection: View {
    let snapshot: TelemetrySnapshot
    @Binding var isExpanded: Bool

    var body: some View {
        TelemetrySectionCard(title: "") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 8) {
                        counterRow("Default path", TelemetryFormat.flag(snapshot.defaultPathAvailable, whenTrue: "Available", whenFalse: "Unavailable"))
                        counterRow("Interface", snapshot.interfaceName ?? TelemetryFormat.unavailable)
                        counterRow("Expensive", TelemetryFormat.flag(snapshot.isExpensive, whenTrue: "Yes", whenFalse: "No"))
                        counterRow("Constrained", TelemetryFormat.flag(snapshot.isConstrained, whenTrue: "Yes", whenFalse: "No"))
                        counterRow("IPv4", TelemetryFormat.flag(snapshot.ipv4Available, whenTrue: "Available", whenFalse: "Unavailable"))
                        counterRow("IPv6", TelemetryFormat.flag(snapshot.ipv6Available, whenTrue: "Available", whenFalse: "Unavailable"))
                    }

                    Divider().background(Color.appSeparator)

                    Text("Recovery")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                    VStack(spacing: 8) {
                        counterRow("Tunnel state", snapshot.connectionState.title)
                        counterRow("Reconnect attempt", "\(snapshot.reconnectAttempt)")
                        counterRow("Last reconnect", snapshot.lastReconnectDate.map { TelemetryFormat.relativeSeconds($0) } ?? "None")
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Text("Network")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    StatusPill(label: snapshot.interfaceName ?? TelemetryFormat.unavailable, tint: .appAccent)
                }
            }
            .tint(Color.appAccent)
        }
    }

    private func counterRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appSecondaryText)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }
}

// MARK: - Recent events

private struct RecentEventsSection: View {
    let events: [TelemetryEvent]
    let onViewAll: () -> Void

    private var recent: [TelemetryEvent] {
        Array(events.suffix(5).reversed())
    }

    var body: some View {
        TelemetrySectionCard(title: "") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Events")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Button(action: onViewAll) {
                        HStack(spacing: 3) {
                            Text("View all logs")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appAccent)
                    }
                }

                if recent.isEmpty {
                    Text("No events yet")
                        .font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                } else {
                    VStack(spacing: 6) {
                        ForEach(recent) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(event.kind.tint)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(timeString(event.timestamp))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.appSecondaryText)
                                Text(event.message)
                                    .font(.caption)
                                    .foregroundStyle(Color.appPrimaryText)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

#Preview("Tunnel Health") {
    ScrollView {
        TelemetryHealthView(viewModel: TelemetryViewModel(vpnService: VPNService()))
            .padding()
    }
    .background(Color.appBackground)
}

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

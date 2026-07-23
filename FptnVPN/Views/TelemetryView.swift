/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

/// Live tunnel dashboard: "is it healthy" at a glance, with raw counters tucked
/// one level down behind Tunnel Health. See TelemetryChartsView / TelemetryHealthView
/// for the rest of the screen; this file owns the header, metric grid, and totals.
struct TelemetryView: View {
    @StateObject private var viewModel = TelemetryViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if viewModel.snapshot.availability.needsBanner {
                        AvailabilityBanner(availability: viewModel.snapshot.availability)
                    }

                    ConnectionHeaderCard(snapshot: viewModel.snapshot)

                    metricGrid

                    TelemetryChartsView(viewModel: viewModel)

                    SessionTotalsCard(snapshot: viewModel.snapshot)

                    TelemetryHealthView(viewModel: viewModel)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.appBackground)
            .navigationTitle("Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.appAccent)
                }
            }
            .onAppear { viewModel.start() }
            .onDisappear { viewModel.stop() }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "Memory",
                value: TelemetryFormat.megabytes(viewModel.snapshot.memoryPhysicalMB),
                caption: "Peak \(TelemetryFormat.megabytes(viewModel.snapshot.memoryPeakMB))",
                tint: memoryTint,
                icon: "memorychip"
            )
            MetricCard(
                title: "Thermal",
                value: viewModel.snapshot.thermalState.label,
                caption: viewModel.snapshot.lowPowerModeEnabled ? "Low Power Mode" : nil,
                tint: viewModel.snapshot.thermalState.tint,
                icon: "thermometer.medium"
            )
            MetricCard(
                title: "Download",
                value: TelemetryFormat.mbps(viewModel.snapshot.downloadMbps),
                caption: "\(TelemetryFormat.dataVolume(viewModel.snapshot.sessionDownloadBytes)) this session",
                tint: .appAccent,
                icon: "arrow.down"
            )
            MetricCard(
                title: "Upload",
                value: TelemetryFormat.mbps(viewModel.snapshot.uploadMbps),
                caption: "\(TelemetryFormat.dataVolume(viewModel.snapshot.sessionUploadBytes)) this session",
                tint: .appAccent,
                icon: "arrow.up"
            )
        }
    }

    private var memoryTint: Color {
        let mb = viewModel.snapshot.memoryPhysicalMB
        if mb >= TelemetrySnapshot.memoryCriticalMB { return .appError }
        if mb >= TelemetrySnapshot.memoryWarningMB { return .appWarning }
        return .appSuccess
    }
}

// MARK: - Connection header

private struct ConnectionHeaderCard: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    if snapshot.connectionState.showsActivity {
                        ProgressView().tint(snapshot.connectionState.tint)
                    } else {
                        Circle()
                            .fill(snapshot.connectionState.tint)
                            .frame(width: 9, height: 9)
                    }
                    Text(snapshot.connectionState.title)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                }
                Spacer()
                LiveIndicator(availability: snapshot.availability)
            }

            if snapshot.connectionState == .connected {
                Text("\(snapshot.serverName) \u{00B7} \(snapshot.interfaceName) \u{00B7} \(TelemetryFormat.duration(snapshot.connectedDuration))")
                    .font(.subheadline)
                    .foregroundStyle(Color.appSecondaryText)

                Text("Episode \(snapshot.episodeID) \u{00B7} Generation \(snapshot.generation)")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText.opacity(0.8))
            } else {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ZStack {
                Color.appElevatedSurface
                RadialGradient(
                    colors: [snapshot.connectionState.tint.opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 220
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var subtitle: String {
        switch snapshot.connectionState {
        case .connecting: return "Selecting and starting tunnel"
        case .reconnecting: return "Existing tunnel is recovering"
        case .disconnecting: return "Live polling stopped \u{00B7} final summary pending"
        case .waitingForNetwork: return "Waiting for a usable network path"
        case .disconnected: return "Last session ended"
        case .connected: return ""
        }
    }
}

private struct LiveIndicator: View {
    let availability: TelemetryAvailability
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(availability.tint)
                .frame(width: 6, height: 6)
                .opacity(availability == .live ? (pulse ? 1 : 0.35) : 1)
                .animation(availability == .live ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(availability == .live ? "Live" : availability.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(availability.tint)
        }
        .onAppear { pulse = true }
    }
}

private struct AvailabilityBanner: View {
    let availability: TelemetryAvailability

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(availability.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(availability.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Text(availability.detail)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(availability.tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var iconName: String {
        switch availability {
        case .stale: return "clock.arrow.circlepath"
        case .paused: return "pause.circle"
        case .providerStopping: return "power"
        case .unavailable, .unsupported: return "exclamationmark.triangle"
        case .live: return "checkmark.circle"
        }
    }
}

// MARK: - Metric card

struct MetricCard: View {
    let title: String
    let value: String
    var caption: String?
    let tint: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appElevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Session totals

private struct SessionTotalsCard: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        TelemetrySectionCard(title: "Session Totals") {
            VStack(spacing: 10) {
                totalRow("Downloaded", TelemetryFormat.dataVolume(snapshot.sessionDownloadBytes))
                totalRow("Uploaded", TelemetryFormat.dataVolume(snapshot.sessionUploadBytes))
                totalRow("Average download", TelemetryFormat.mbps(snapshot.averageDownloadMbps))
                totalRow("Average upload", TelemetryFormat.mbps(snapshot.averageUploadMbps))
                totalRow("Connected time", TelemetryFormat.duration(snapshot.connectedDuration))
                totalRow("Reconnects", "\(snapshot.reconnectCount)")
            }
        }
    }

    private func totalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.appSecondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }
}

// MARK: - Shared building blocks

/// The card shell reused across the Telemetry screen's sections.
struct TelemetrySectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appElevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}

struct StatusPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }
}

#Preview("Telemetry \u{2013} Connected") {
    TelemetryView()
}

#Preview("Telemetry \u{2013} Connected Dark") {
    TelemetryView()
        .preferredColorScheme(.dark)
}

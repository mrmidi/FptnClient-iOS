/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import Charts

/// Memory and bandwidth charts, sharing one time-window control.
/// Memory is the primary chart: its target/warning/critical reference bands are
/// the screen's signature "vitals monitor" element — the fastest possible read on
/// whether the tunnel is healthy, echoed by the same three colors on the metric cards.
struct TelemetryChartsView: View {
    @ObservedObject var viewModel: TelemetryViewModel

    var body: some View {
        VStack(spacing: 12) {
            MemoryChartCard(
                samples: viewModel.filteredMemorySamples(),
                snapshot: viewModel.snapshot,
                selectedWindow: $viewModel.selectedWindow
            )
            BandwidthChartCard(
                samples: viewModel.filteredBandwidthSamples(),
                snapshot: viewModel.snapshot,
                selectedWindow: $viewModel.selectedWindow
            )
        }
    }
}

private struct TimeWindowPicker: View {
    @Binding var selection: TelemetryTimeWindow

    var body: some View {
        Picker("Window", selection: $selection) {
            ForEach(TelemetryTimeWindow.allCases) { window in
                Text(window.label).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color.appAccent)
        .frame(width: 168)
        .fixedSize()
    }
}

// MARK: - Memory chart

private struct MemoryChartCard: View {
    let samples: [MemorySample]
    let snapshot: TelemetrySnapshot
    @Binding var selectedWindow: TelemetryTimeWindow

    private var yCeiling: Double {
        let sampleMax = samples.map(\.physicalMB).max() ?? TelemetrySnapshot.memoryChartCeilingMB
        return max(TelemetrySnapshot.memoryChartCeilingMB, sampleMax * 1.1)
    }

    private var currentTint: Color {
        if snapshot.memoryPhysicalMB >= TelemetrySnapshot.memoryCriticalMB { return .appError }
        if snapshot.memoryPhysicalMB >= TelemetrySnapshot.memoryWarningMB { return .appWarning }
        return .appSuccess
    }

    var body: some View {
        TelemetrySectionCard(title: "") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        Text("Current \(TelemetryFormat.megabytes(snapshot.memoryPhysicalMB)) \u{00B7} Peak \(TelemetryFormat.megabytes(snapshot.memoryPeakMB))")
                            .font(.caption)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    Spacer()
                    TimeWindowPicker(selection: $selectedWindow)
                }

                chartBody
                    .frame(height: 150)

                legend
            }
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        if samples.isEmpty {
            EmptyChartPlaceholder(
                title: "Waiting for memory samples",
                detail: "Memory is sampled by the tunnel while connected"
            )
        } else {
            Chart {
                RectangleMark(
                    yStart: .value("Target min", TelemetrySnapshot.memoryTargetRange.lowerBound),
                    yEnd: .value("Target max", TelemetrySnapshot.memoryTargetRange.upperBound)
                )
                .foregroundStyle(Color.appSuccess.opacity(0.10))

                RuleMark(y: .value("Warning", TelemetrySnapshot.memoryWarningMB))
                    .foregroundStyle(Color.appWarning.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                RuleMark(y: .value("Critical", TelemetrySnapshot.memoryCriticalMB))
                    .foregroundStyle(Color.appError.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("MB", sample.physicalMB)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [currentTint.opacity(0.28), currentTint.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("MB", sample.physicalMB)
                    )
                    .foregroundStyle(currentTint)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...yCeiling)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.appSeparator.opacity(0.3))
                    AxisValueLabel {
                        if let mb = value.as(Double.self) {
                            Text("\(Int(mb))")
                                .font(.caption2)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .appSuccess.opacity(0.5), label: "Target 20\u{2013}25 MB", isLine: false)
            legendItem(color: .appWarning, label: "Warning 30 MB", isLine: true)
            legendItem(color: .appError, label: "Critical 42 MB", isLine: true)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Color.appSecondaryText)
    }

    private func legendItem(color: Color, label: String, isLine: Bool) -> some View {
        HStack(spacing: 4) {
            if isLine {
                Rectangle().fill(color).frame(width: 8, height: 2)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
        }
    }
}

// MARK: - Bandwidth chart

private struct BandwidthChartCard: View {
    static let uploadTint = Color(red: 0.44, green: 0.24, blue: 0.86)

    let samples: [BandwidthSample]
    let snapshot: TelemetrySnapshot
    @Binding var selectedWindow: TelemetryTimeWindow

    var body: some View {
        TelemetrySectionCard(title: "") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bandwidth")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        HStack(spacing: 10) {
                            rateLabel(symbol: "arrow.down", value: snapshot.downloadMbps, tint: .appAccent)
                            rateLabel(symbol: "arrow.up", value: snapshot.uploadMbps, tint: Self.uploadTint)
                        }
                        Text("Peak \u{2193} \(TelemetryFormat.mbps(snapshot.downloadPeakMbps))  \u{2191} \(TelemetryFormat.mbps(snapshot.uploadPeakMbps))")
                            .font(.caption2)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    Spacer()
                    TimeWindowPicker(selection: $selectedWindow)
                }

                chartBody
                    .frame(height: 130)

                Text("Tunnel download / upload \u{00B7} not raw interface traffic")
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText.opacity(0.8))
            }
        }
    }

    private func rateLabel(symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(TelemetryFormat.mbps(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        if samples.isEmpty {
            EmptyChartPlaceholder(title: "No tunnel traffic yet", detail: nil)
        } else {
            Chart {
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.downloadMbps)
                    )
                    .foregroundStyle(LinearGradient(colors: [Color.appAccent.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.downloadMbps)
                    )
                    .foregroundStyle(Color.appAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.uploadMbps)
                    )
                    .foregroundStyle(Self.uploadTint)
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
                    .interpolationMethod(.catmullRom)
                }

                if let last = samples.last {
                    PointMark(x: .value("Time", last.timestamp), y: .value("Mbps", last.downloadMbps))
                        .foregroundStyle(Color.appAccent)
                        .symbolSize(36)
                    PointMark(x: .value("Time", last.timestamp), y: .value("Mbps", last.uploadMbps))
                        .foregroundStyle(Self.uploadTint)
                        .symbolSize(36)
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.appSeparator.opacity(0.3))
                    AxisValueLabel {
                        if let mbps = value.as(Double.self) {
                            Text(String(format: "%.0f", mbps))
                                .font(.caption2)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }
            }
        }
    }
}

private struct EmptyChartPlaceholder: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.appSecondaryText)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.appSecondaryText.opacity(0.7))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

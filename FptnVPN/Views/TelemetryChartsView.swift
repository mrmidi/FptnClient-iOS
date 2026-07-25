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
                samples: viewModel.displayMemorySamples,
                snapshot: viewModel.snapshot,
                selectedWindow: $viewModel.selectedWindow
            )
            BandwidthChartCard(
                samples: viewModel.displayBandwidthSamples,
                snapshot: viewModel.snapshot,
                selectedWindow: $viewModel.selectedWindow
            )
        }
    }
}

/// The x range the window picker actually selects.
///
/// Without this the charts use `.automatic`, which fits the axis to whatever
/// samples survived filtering — so 1m / 5m / All only changed the data, never
/// the scale, and a 90-second session was drawn edge-to-edge under "5m",
/// implying a spacing between events that wasn't real.
private func chartXDomain(
    window: TelemetryTimeWindow,
    end: Date,
    earliestSample: Date?
) -> ClosedRange<Date> {
    if let duration = window.duration {
        return end.addingTimeInterval(-duration)...end
    }
    // "All" spans the retained buffer. Guard the degenerate range that a
    // single sample (or none) would otherwise produce.
    guard let earliest = earliestSample, earliest < end else {
        return end.addingTimeInterval(-60)...end
    }
    return earliest...end
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

    // Fixed line tint. Severity is conveyed by the target band + warning/
    // critical rule lines and the metric card above — the historical line must
    // not be repainted by whatever the *current* value happens to be, which
    // would (mis)colour minutes of healthy history red the instant memory
    // spikes.
    private let lineTint = Color.appAccent

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
        if samples.count < 2 {
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
                    // Keyed by segment so a stretch where the live feed was
                    // absent breaks the line instead of being bridged.
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("MB", sample.physicalMB),
                        series: .value("Segment", sample.segmentID)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [lineTint.opacity(0.28), lineTint.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Linear, not catmullRom: a monotone/spline overshoots
                    // between the sparse memory samples, inventing peaks and
                    // dips that were never measured — misleading on a vitals
                    // chart. Straight segments only connect real samples.
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("MB", sample.physicalMB),
                        series: .value("Segment", sample.segmentID)
                    )
                    .foregroundStyle(lineTint)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.linear)
                }
            }
            .transaction { $0.animation = nil }
            .chartXAxis(.hidden)
            .chartXScale(domain: chartXDomain(
                window: selectedWindow,
                end: snapshot.lastUpdated,
                earliestSample: samples.first?.timestamp
            ))
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
            legendItem(color: .appSuccess.opacity(0.5), label: "Target \(Int(TelemetrySnapshot.memoryTargetRange.lowerBound))\u{2013}\(Int(TelemetrySnapshot.memoryTargetRange.upperBound)) MB", isLine: false)
            legendItem(color: .appWarning, label: "Warning \(Int(TelemetrySnapshot.memoryWarningMB)) MB", isLine: true)
            legendItem(color: .appError, label: "Critical \(Int(TelemetrySnapshot.memoryCriticalMB)) MB", isLine: true)
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
                        Text("Peak \u{2193} \(TelemetryFormat.bitrate(snapshot.downloadPeakMbps))  \u{2191} \(TelemetryFormat.bitrate(snapshot.uploadPeakMbps))")
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
            Text(TelemetryFormat.bitrate(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.appPrimaryText)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        if samples.count < 2 {
            EmptyChartPlaceholder(title: "No tunnel traffic yet", detail: nil)
        } else {
            Chart {
                ForEach(samples) { sample in
                    // Series keys carry both direction and segment: direction
                    // so the two traces stay separate lines, segment so a
                    // stretch where the live feed was absent breaks them
                    // rather than being drawn as a slope through no data.
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.downloadMbps),
                        series: .value("Series", "down-\(sample.segmentID)")
                    )
                    .foregroundStyle(LinearGradient(colors: [Color.appAccent.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.downloadMbps),
                        series: .value("Series", "down-\(sample.segmentID)")
                    )
                    .foregroundStyle(Color.appAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Mbps", sample.uploadMbps),
                        series: .value("Series", "up-\(sample.segmentID)")
                    )
                    .foregroundStyle(Self.uploadTint)
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
                    .interpolationMethod(.linear)
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
            .transaction { $0.animation = nil }
            .chartXAxis(.hidden)
            .chartXScale(domain: chartXDomain(
                window: selectedWindow,
                end: snapshot.lastUpdated,
                earliestSample: samples.first?.timestamp
            ))
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

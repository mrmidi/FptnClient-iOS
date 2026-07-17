/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
============================================================================*/

import SwiftUI
import Charts

struct SpeedChartView: View {
    let samples: [SpeedSample]

    private static let maxSamples = 300

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.downloadMbps)
                )
                .foregroundStyle(Color.green)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.downloadMbps)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.green.opacity(0.3), Color.green.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.uploadMbps)
                )
                .foregroundStyle(Color.blue)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.uploadMbps)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let mbps = value.as(Double.self) {
                        Text(String(format: "%.1f", mbps))
                            .font(.caption2)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .frame(height: 120)
    }
}

/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

public struct AcceptanceReport: Codable, Sendable {
    public let totalProbes: Int
    public let successCount: Int
    public let failureCount: Int
    public let successRate: Double
    
    public let minLatencyMs: Int?
    public let maxLatencyMs: Int?
    public let avgLatencyMs: Double?
    public let p50LatencyMs: Int?
    public let p90LatencyMs: Int?
    public let p95LatencyMs: Int?
    
    public let failuresByKind: [String: Int]
}

public struct ReportGenerator {
    public static func generate(from observations: [ServerHealthObservation]) -> AcceptanceReport {
        let total = observations.count
        let successes = observations.filter { $0.outcome == .success }
        let failures = observations.filter { $0.outcome != .success }
        
        let successRate = total > 0 ? Double(successes.count) / Double(total) : 0.0
        let sortedLatencies = successes.compactMap { $0.totalBootstrapMs }.sorted()
        
        let minLat = sortedLatencies.first
        let maxLat = sortedLatencies.last
        let avgLat: Double? = sortedLatencies.isEmpty ? nil : Double(sortedLatencies.reduce(0, +)) / Double(sortedLatencies.count)
        
        let p50 = percentile(sortedLatencies, p: 50)
        let p90 = percentile(sortedLatencies, p: 90)
        let p95 = percentile(sortedLatencies, p: 95)
        
        var failuresByKind: [String: Int] = [:]
        for failure in failures {
            failuresByKind[failure.outcome.rawValue, default: 0] += 1
        }
        
        return AcceptanceReport(
            totalProbes: total,
            successCount: successes.count,
            failureCount: failures.count,
            successRate: successRate,
            minLatencyMs: minLat,
            maxLatencyMs: maxLat,
            avgLatencyMs: avgLat,
            p50LatencyMs: p50,
            p90LatencyMs: p90,
            p95LatencyMs: p95,
            failuresByKind: failuresByKind
        )
    }

    public static func generate(from metrics: [ProbeMetrics]) -> AcceptanceReport {
        let total = metrics.count
        let successes = metrics.filter { $0.outcome == .success }
        let failures = metrics.filter { $0.outcome == .failure }
        
        let successRate = total > 0 ? Double(successes.count) / Double(total) : 0.0
        let sortedLatencies = successes.map { $0.totalMs }.sorted()
        
        let minLat = sortedLatencies.first
        let maxLat = sortedLatencies.last
        let avgLat: Double? = sortedLatencies.isEmpty ? nil : Double(sortedLatencies.reduce(0, +)) / Double(sortedLatencies.count)
        
        let p50 = percentile(sortedLatencies, p: 50)
        let p90 = percentile(sortedLatencies, p: 90)
        let p95 = percentile(sortedLatencies, p: 95)
        
        return AcceptanceReport(
            totalProbes: total,
            successCount: successes.count,
            failureCount: failures.count,
            successRate: successRate,
            minLatencyMs: minLat,
            maxLatencyMs: maxLat,
            avgLatencyMs: avgLat,
            p50LatencyMs: p50,
            p90LatencyMs: p90,
            p95LatencyMs: p95,
            failuresByKind: [:]
        )
    }
    
    public static func generate(from attempts: [ServerBootstrapAttempt]) -> AcceptanceReport {
        var metrics: [ProbeMetrics] = []
        var failuresByKind: [String: Int] = [:]
        
        for attempt in attempts {
            switch attempt {
            case .success(let res):
                metrics.append(res.metrics)
            case .failure(let fail):
                metrics.append(fail.metrics)
                let kindStr = fail.kind.rawValue
                failuresByKind[kindStr, default: 0] += 1
            }
        }
        
        let baseReport = generate(from: metrics)
        return AcceptanceReport(
            totalProbes: baseReport.totalProbes,
            successCount: baseReport.successCount,
            failureCount: baseReport.failureCount,
            successRate: baseReport.successRate,
            minLatencyMs: baseReport.minLatencyMs,
            maxLatencyMs: baseReport.maxLatencyMs,
            avgLatencyMs: baseReport.avgLatencyMs,
            p50LatencyMs: baseReport.p50LatencyMs,
            p90LatencyMs: baseReport.p90LatencyMs,
            p95LatencyMs: baseReport.p95LatencyMs,
            failuresByKind: failuresByKind
        )
    }
    
    private static func percentile(_ sorted: [Int], p: Int) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let index = Int(ceil(Double(p) / 100.0 * Double(sorted.count))) - 1
        let safeIndex = max(0, min(sorted.count - 1, index))
        return sorted[safeIndex]
    }
    
    public static func renderToConsole(report: AcceptanceReport) {
        print("\n================ ACCEPTANCE REPORT ================")
        print("Total Probes Executed: \(report.totalProbes)")
        print("Successes:            \(report.successCount)")
        print("Failures:             \(report.failureCount)")
        print("Success Rate:         \(String(format: "%.2f%%", report.successRate * 100))")
        print("---------------------------------------------------")
        if let avg = report.avgLatencyMs {
            print("Latency Statistics (Successes Only):")
            print("  Min:                \(report.minLatencyMs ?? 0) ms")
            print("  Average:            \(String(format: "%.2f", avg)) ms")
            print("  p50 (Median):       \(report.p50LatencyMs ?? 0) ms")
            print("  p90:                \(report.p90LatencyMs ?? 0) ms")
            print("  p95:                \(report.p95LatencyMs ?? 0) ms")
            print("  Max:                \(report.maxLatencyMs ?? 0) ms")
        } else {
            print("No latency metrics available (zero successful probes)")
        }
        if !report.failuresByKind.isEmpty {
            print("---------------------------------------------------")
            print("Failures breakdown by kind:")
            for (kind, count) in report.failuresByKind.sorted(by: { $0.value > $1.value }) {
                print("  \(kind): \(count)")
            }
        }
        print("===================================================\n")
    }
}

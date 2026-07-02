/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import MetricKit

final class MetricKitManager: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitManager()

    private override init() {
        super.init()
        MXMetricManager.shared.add(self)
        logger.info("MetricKitManager initialized")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let dict = payload.dictionaryRepresentation()
            let cpu = Self.nestedString(dict, "cpuMetrics", "cumulativeCPUTime")
            let mem = Self.nestedString(dict, "memoryMetrics", "peakMemoryUsage")
            let hang = Self.nestedString(dict, "applicationResponsivenessMetrics",
                                         "histogrammedAppHangTime")
            let begin = dict["timeStampBegin"].map { String(describing: $0) } ?? "-"
            let end   = dict["timeStampEnd"].map   { String(describing: $0) } ?? "-"
            logger.info(
                "MetricKit period=[\(begin) – \(end)] cpu=\(cpu ?? "-") peakMem=\(mem ?? "-") hang=\(hang != nil ? "YES — check debug log" : "none")"
            )
            logger.debug("MetricKit full payload: \(dict)")
        }
    }

    private static func nestedString(_ dict: [AnyHashable: Any], _ keys: String...) -> String? {
        var current: Any = dict
        for key in keys {
            guard let d = current as? [AnyHashable: Any], let next = d[key] else { return nil }
            current = next
        }
        return current is NSNull ? nil : String(describing: current)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            logger.warning("MetricKit diagnostic payload received")

            if let crashDiagnostics = payload.crashDiagnostics {
                for crash in crashDiagnostics {
                    logger.error("MetricKit crash: \(crash)")
                    persistDiagnostic(category: "crash", dictionary: crash.dictionaryRepresentation())
                }
            }

            if let hangDiagnostics = payload.hangDiagnostics {
                for hang in hangDiagnostics {
                    logger.warning("MetricKit hang: \(hang)")
                    persistDiagnostic(category: "hang", dictionary: hang.dictionaryRepresentation())
                }
            }

            if let cpuExceptionDiagnostics = payload.cpuExceptionDiagnostics {
                for cpuException in cpuExceptionDiagnostics {
                    logger.warning("MetricKit CPU exception: \(cpuException)")
                    persistDiagnostic(category: "cpu_exception", dictionary: cpuException.dictionaryRepresentation())
                }
            }

            if let diskWriteExceptionDiagnostics = payload.diskWriteExceptionDiagnostics {
                for diskWrite in diskWriteExceptionDiagnostics {
                    logger.warning("MetricKit disk write exception: \(diskWrite)")
                    persistDiagnostic(category: "disk_write_exception", dictionary: diskWrite.dictionaryRepresentation())
                }
            }
        }
    }

    private func persistDiagnostic(category: String, dictionary: Any) {
        let normalizedDictionary = Self.normalizedForJSON(dictionary)
        let payload = Self.stableDescription(normalizedDictionary)
        let record = MetricKitDiagnosticRecord(
            timestamp: TunnelDiagnosticsStore.now(),
            category: category,
            processName: Self.firstString(in: normalizedDictionary, keys: ["processName", "binaryName", "applicationName"]),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            exceptionType: Self.firstString(in: normalizedDictionary, keys: ["exceptionType", "terminationReason", "hangType"]),
            exceptionCode: Self.firstString(in: normalizedDictionary, keys: ["exceptionCode", "signal", "terminationSignal"]),
            terminationReason: Self.firstString(in: normalizedDictionary, keys: ["terminationReason", "terminationNamespace"]),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            callStack: Self.callStackText(from: normalizedDictionary),
            payload: TunnelDiagnosticsRedactor.redact(payload)
        )
        TunnelDiagnosticsStore.shared.recordMetricKitDiagnostic(record)
    }

    private static func normalizedForJSON(_ value: Any) -> Any {
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[String(describing: entry.key)] = normalizedForJSON(entry.value)
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = normalizedForJSON(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(normalizedForJSON)
        }
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if value is NSNull || value is String || value is NSNumber {
            return value
        }
        return String(describing: value)
    }

    private static func stableDescription(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func firstString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [AnyHashable: Any] {
            for (key, nested) in dictionary {
                if keys.contains(String(describing: key)), !(nested is NSNull) {
                    return String(describing: nested)
                }
                if let found = firstString(in: nested, keys: keys) {
                    return found
                }
            }
        }
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if keys.contains(key), !(nested is NSNull) {
                    return String(describing: nested)
                }
                if let found = firstString(in: nested, keys: keys) {
                    return found
                }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let found = firstString(in: nested, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func callStackText(from value: Any) -> String? {
        firstString(in: value, keys: ["callStackTree", "callStacks", "stackFrames", "frames"])
    }
}

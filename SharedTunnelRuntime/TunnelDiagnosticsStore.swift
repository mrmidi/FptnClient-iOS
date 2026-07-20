import Darwin
import Foundation

struct TunnelDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: String
    let source: String
    let category: String
    let message: String
    let runtimeState: String?
    let generation: Int?
    let reconnectAttempt: Int?
    let pathSatisfied: Bool?
}

struct TunnelProviderHeartbeat: Codable, Equatable, Sendable {
    let timestamp: String
    let runtimeState: String
    let isReasserting: Bool
    let generation: Int
    let reconnectAttempt: Int
    let maxReconnectAttempts: Int
    let pathSatisfied: Bool
    let websocketStarted: Bool
    let websocketRunning: Bool
    let lastTransportError: String?
    let lastStopReason: String?
    let lastEvent: String?
    let lastInboundActivityAt: String?
    let lastOutboundActivityAt: String?
    let packetFlowReadPackets: Int64
    let packetFlowWritePackets: Int64
    let transportReceivedPackets: Int64
    let websocketSendFailures: Int64
    let memoryResidentBytes: UInt64?
    let memoryPhysFootprintBytes: UInt64?
}

enum TunnelMemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case emergency
}

// PR-1 (Measurement Safety): the provider's response to memory pressure.
// Both warning and emergency are log-only — no bridge stop, replacement,
// or reconnect is ever triggered by memory thresholds.
enum TunnelMemoryPressureAction: Equatable, Sendable {
    case none
    case logOnly

    static func action(for level: TunnelMemoryPressureLevel) -> TunnelMemoryPressureAction {
        switch level {
        case .normal:
            return .none
        case .warning, .emergency:
            return .logOnly
        }
    }
}

struct TunnelMemoryPressureSnapshot: Equatable, Sendable {
    static let warningThresholdBytes: UInt64 = 30 * 1024 * 1024
    static let emergencyThresholdBytes: UInt64 = 42 * 1024 * 1024

    let residentBytes: UInt64?
    let physFootprintBytes: UInt64?

    var primaryBytes: UInt64? {
        physFootprintBytes ?? residentBytes
    }

    var level: TunnelMemoryPressureLevel {
        guard let primaryBytes else { return .normal }
        if primaryBytes >= Self.emergencyThresholdBytes {
            return .emergency
        }
        if primaryBytes >= Self.warningThresholdBytes {
            return .warning
        }
        return .normal
    }

    var description: String {
        "memory_rss=\(Self.megabytesDescription(residentBytes)) memory_footprint=\(Self.megabytesDescription(physFootprintBytes)) memory_level=\(level.rawValue)"
    }

    static func megabytesDescription(_ bytes: UInt64?) -> String {
        guard let bytes else { return "-" }
        return "\(bytes / 1024 / 1024)MB"
    }
}

struct TunnelCrashMarker: Codable, Equatable, Sendable {
    let timestamp: String
    let signal: Int32
    let signalName: String
    let process: String
}

struct MetricKitDiagnosticRecord: Codable, Equatable, Sendable {
    let timestamp: String
    let category: String
    let processName: String?
    let bundleIdentifier: String?
    let exceptionType: String?
    let exceptionCode: String?
    let terminationReason: String?
    let appVersion: String?
    let appBuild: String?
    let callStack: String?
    let payload: String
}

struct TunnelProviderFailureReport: Equatable, Sendable {
    let generatedAt: String
    let disconnectReason: String
    let heartbeat: TunnelProviderHeartbeat?
    let heartbeatAgeSeconds: Int?
    let crashMarker: TunnelCrashMarker?
    let nearestMetricKitDiagnostic: MetricKitDiagnosticRecord?
    let recentEvents: [TunnelDiagnosticEvent]

    var summaryLine: String {
        let heartbeatState = heartbeat?.runtimeState ?? "missing"
        let heartbeatAge = heartbeatAgeSeconds.map { "\($0)s" } ?? "-"
        let lastEvent = heartbeat?.lastEvent ?? recentEvents.last?.message ?? "-"
        let marker = crashMarker.map { "\($0.signalName)(\($0.signal))" } ?? "none"
        let metric = nearestMetricKitDiagnostic.map { "\($0.category)@\($0.timestamp)" } ?? "none_yet"
        let memory = heartbeat.map {
            "rss=\(TunnelMemoryPressureSnapshot.megabytesDescription($0.memoryResidentBytes)) footprint=\(TunnelMemoryPressureSnapshot.megabytesDescription($0.memoryPhysFootprintBytes))"
        } ?? "memory=-"
        let vanished = heartbeatAgeSeconds.map { $0 > 45 } ?? true
        let classification = vanished ? "provider_missing_without_last_gasp" : "provider_failed_with_recent_heartbeat"
        return "Provider failure diagnostics classification=\(classification) disconnect_reason=\(disconnectReason) heartbeat_state=\(heartbeatState) heartbeat_age=\(heartbeatAge) \(memory) last_event=\(lastEvent) crash_marker=\(marker) nearest_metrickit=\(metric)"
    }

    var exportText: String {
        var lines: [String] = [summaryLine]
        if let heartbeat {
            lines.append("Heartbeat: state=\(heartbeat.runtimeState) reasserting=\(heartbeat.isReasserting) generation=\(heartbeat.generation) reconnect_attempt=\(heartbeat.reconnectAttempt)/\(heartbeat.maxReconnectAttempts == 0 ? "∞" : String(heartbeat.maxReconnectAttempts)) path_satisfied=\(heartbeat.pathSatisfied) ws_started=\(heartbeat.websocketStarted) ws_running=\(heartbeat.websocketRunning) send_failures=\(heartbeat.websocketSendFailures) rss=\(TunnelMemoryPressureSnapshot.megabytesDescription(heartbeat.memoryResidentBytes)) footprint=\(TunnelMemoryPressureSnapshot.megabytesDescription(heartbeat.memoryPhysFootprintBytes)) last_error=\(heartbeat.lastTransportError ?? "-") last_stop=\(heartbeat.lastStopReason ?? "-") last_inbound=\(heartbeat.lastInboundActivityAt ?? "-") last_outbound=\(heartbeat.lastOutboundActivityAt ?? "-")")
        }
        if let crashMarker {
            lines.append("Crash marker: signal=\(crashMarker.signalName)(\(crashMarker.signal)) timestamp=\(crashMarker.timestamp) process=\(crashMarker.process)")
        }
        if let nearestMetricKitDiagnostic {
            lines.append("Nearest MetricKit: category=\(nearestMetricKitDiagnostic.category) timestamp=\(nearestMetricKitDiagnostic.timestamp) process=\(nearestMetricKitDiagnostic.processName ?? "-") exception=\(nearestMetricKitDiagnostic.exceptionType ?? "-") code=\(nearestMetricKitDiagnostic.exceptionCode ?? "-") termination=\(nearestMetricKitDiagnostic.terminationReason ?? "-")")
        } else {
            lines.append("Nearest MetricKit: none_yet")
        }
        if !recentEvents.isEmpty {
            lines.append("Recent provider events:")
            lines.append(contentsOf: recentEvents.suffix(20).map { "\($0.timestamp) \($0.category) \($0.message)" })
        }
        return lines.joined(separator: "\n")
    }
}

final class TunnelDiagnosticsStore: @unchecked Sendable {
    static let shared = TunnelDiagnosticsStore()

    // PR-1 (Measurement Safety): compile-time gate. In Measurement builds,
    // recordProviderEvent and writeHeartbeat are no-ops. This is a computed
    // property (not mutable state) so no cross-thread race is possible and
    // no call can accidentally write diagnostics before startTunnel runs.
    static var providerRecordingEnabled: Bool {
        #if FPTN_MEASUREMENT_BUILD
        return false
        #else
        return true
        #endif
    }

    private static let appGroup = "group.net.mrmidi.FptnVPN"
    private let queue = DispatchQueue(label: "org.fptn.diagnostics-store", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let providerEventLimit = 300
    private let metricKitLimit = 100
    private let rootURL: URL?

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
                .appendingPathComponent("diagnostics", isDirectory: true)
        }
        if let rootURL = self.rootURL {
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    func recordProviderEvent(
        category: String,
        message: String,
        runtimeState: String? = nil,
        generation: Int? = nil,
        reconnectAttempt: Int? = nil,
        pathSatisfied: Bool? = nil
    ) {
        guard Self.providerRecordingEnabled else { return }
        let event = TunnelDiagnosticEvent(
            timestamp: Self.now(),
            source: "provider",
            category: category,
            message: TunnelDiagnosticsRedactor.redact(message),
            runtimeState: runtimeState,
            generation: generation,
            reconnectAttempt: reconnectAttempt,
            pathSatisfied: pathSatisfied
        )
        append(event, to: .providerEvents, limit: providerEventLimit)
    }

    func writeHeartbeat(_ heartbeat: TunnelProviderHeartbeat) {
        guard Self.providerRecordingEnabled else { return }
        writeJSON(heartbeat, to: .providerHeartbeat)
    }

    func readHeartbeat() -> TunnelProviderHeartbeat? {
        readJSON(TunnelProviderHeartbeat.self, from: .providerHeartbeat)
    }

    func readCrashMarker() -> TunnelCrashMarker? {
        readJSON(TunnelCrashMarker.self, from: .providerCrashMarker)
    }

    func recordMetricKitDiagnostic(_ record: MetricKitDiagnosticRecord) {
        append(record, to: .metricKitDiagnostics, limit: metricKitLimit)
    }

    func readMetricKitDiagnostics() -> [MetricKitDiagnosticRecord] {
        readJSONLines(MetricKitDiagnosticRecord.self, from: .metricKitDiagnostics)
    }

    func readProviderEvents() -> [TunnelDiagnosticEvent] {
        readJSONLines(TunnelDiagnosticEvent.self, from: .providerEvents)
    }

    func makeProviderFailureReport(disconnectReason: String, at date: Date = Date()) -> TunnelProviderFailureReport {
        let heartbeat = readHeartbeat()
        let events = readProviderEvents()
        let marker = readCrashMarker()
        let metrics = readMetricKitDiagnostics()
        let heartbeatAge = heartbeat.flatMap { Self.ageSeconds(since: $0.timestamp, at: date) }
        let nearestMetric = nearestMetricKitDiagnostic(to: date, records: metrics)
        return TunnelProviderFailureReport(
            generatedAt: Self.makeISO8601Formatter().string(from: date),
            disconnectReason: disconnectReason,
            heartbeat: heartbeat,
            heartbeatAgeSeconds: heartbeatAge,
            crashMarker: marker,
            nearestMetricKitDiagnostic: nearestMetric,
            recentEvents: Array(events.suffix(40))
        )
    }

    func exportDiagnosticsText() -> String {
        let report = makeProviderFailureReport(disconnectReason: "manual_export")
        var sections = ["Provider diagnostics", report.exportText]
        let metrics = readMetricKitDiagnostics().suffix(10)
        if !metrics.isEmpty {
            sections.append("Recent MetricKit diagnostics:")
            sections.append(contentsOf: metrics.map { "\($0.timestamp) \($0.category) process=\($0.processName ?? "-") exception=\($0.exceptionType ?? "-") termination=\($0.terminationReason ?? "-")" })
        }
        return TunnelDiagnosticsRedactor.redact(sections.joined(separator: "\n"))
    }

    func clear() {
        queue.sync {
            for file in DiagnosticFile.allCases {
                try? FileManager.default.removeItem(at: url(for: file))
            }
        }
    }

    private func append<T: Encodable & Sendable>(_ value: T, to file: DiagnosticFile, limit: Int) {
        queue.async {
            let url = self.url(for: file)
            var lines = self.readLines(from: url)
            guard let data = try? self.encoder.encode(value),
                  let line = String(data: data, encoding: .utf8) else { return }
            lines.append(line)
            if lines.count > limit {
                lines = Array(lines.suffix(limit))
            }
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func writeJSON<T: Encodable & Sendable>(_ value: T, to file: DiagnosticFile) {
        queue.async {
            let url = self.url(for: file)
            guard let data = try? self.encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from file: DiagnosticFile) -> T? {
        queue.sync {
            let url = self.url(for: file)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    private func readJSONLines<T: Decodable>(_ type: T.Type, from file: DiagnosticFile) -> [T] {
        queue.sync {
            readLines(from: url(for: file)).compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(type, from: data)
            }
        }
    }

    private func readLines(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func nearestMetricKitDiagnostic(to date: Date, records: [MetricKitDiagnosticRecord]) -> MetricKitDiagnosticRecord? {
        records.min { lhs, rhs in
            abs(Self.secondsBetween(lhs.timestamp, and: date) ?? .greatestFiniteMagnitude) <
                abs(Self.secondsBetween(rhs.timestamp, and: date) ?? .greatestFiniteMagnitude)
        }
    }

    private func url(for file: DiagnosticFile) -> URL {
        (rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent(file.rawValue)
    }

    private enum DiagnosticFile: String, CaseIterable {
        case providerEvents = "provider-events.jsonl"
        case providerHeartbeat = "provider-heartbeat.json"
        case providerCrashMarker = "provider-crash-marker.json"
        case metricKitDiagnostics = "metrickit-diagnostics.jsonl"
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func now() -> String {
        makeISO8601Formatter().string(from: Date())
    }

    static func ageSeconds(since timestamp: String, at date: Date = Date()) -> Int? {
        secondsBetween(timestamp, and: date).map { max(0, Int($0.rounded())) }
    }

    private static func secondsBetween(_ timestamp: String, and date: Date) -> TimeInterval? {
        guard let parsed = makeISO8601Formatter().date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
            return nil
        }
        return date.timeIntervalSince(parsed)
    }
}

enum TunnelDiagnosticsRedactor {
    static func redact(_ input: String) -> String {
        var text = input
        let patterns: [(String, String)] = [
            (#"(?<![A-Za-z0-9])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(?![A-Za-z0-9])"#, "<redacted-ipv4>"),
            (#"(?i)(?<![A-Za-z0-9])(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}(?:%[A-Za-z0-9_.-]+)?(?![A-Za-z0-9])"#, "<redacted-ipv6>"),
            (#"(?i)(access[_-]?token\"?\s*[:=]\s*\"?)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(password\"?\s*[:=]\s*\"?)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(authorization\"?\s*[:=]?\s*\"?bearer\s+)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(token\"?\s*[:=]\s*\"?)([^\",\s]{8,})"#, "$1<redacted>")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }
}

enum TunnelCrashSignalInstaller {
    nonisolated(unsafe) private static var markerFD: Int32 = -1
    private static let processName = "FptnVPNTunnel"

    static func installIfPossible() {
        guard markerFD == -1,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.mrmidi.FptnVPN") else {
            return
        }
        let diagnosticsDir = container.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)
        let path = diagnosticsDir.appendingPathComponent("provider-crash-marker.json").path
        markerFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard markerFD >= 0 else { return }

        signal(SIGABRT, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGTRAP, signalHandler)
    }

    private static let signalHandler: @convention(c) (Int32) -> Void = { signalNumber in
        guard markerFD >= 0 else { return }
        let name = signalName(signalNumber)
        let message = "{\"timestamp\":\"signal-time-unavailable\",\"signal\":\(signalNumber),\"signalName\":\"\(name)\",\"process\":\"\(processName)\"}\n"
        message.withCString { pointer in
            _ = ftruncate(markerFD, 0)
            _ = lseek(markerFD, 0, SEEK_SET)
            _ = write(markerFD, pointer, strlen(pointer))
            _ = fsync(markerFD)
        }
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    private static func signalName(_ signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIGNAL"
        }
    }
}

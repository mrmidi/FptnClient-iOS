/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class LogsViewModel: ObservableObject {
    enum SourceFilter: String, CaseIterable, Identifiable {
        case all
        case app
        case tunnel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "All"
            case .app: return "App"
            case .tunnel: return "Tunnel"
            }
        }
    }

    struct LogEntry: Identifiable, Sendable {
        let id: Int
        let raw: String
        let level: LogLevel
        let source: SourceFilter
        let timestamp: Date?
    }

    @Published var selectedLevel: LogLevel
    @Published var selectedSource: SourceFilter = .all
    @Published var showRecentOnly = true
    @Published private(set) var entries: [LogEntry] = []
    @Published var isFollowing = true

    private let settingsService: SettingsService
    private let recentWindow: TimeInterval = 24 * 60 * 60
    private let refreshIntervalNs: UInt64 = 1_000_000_000
    private var refreshTask: Task<Void, Never>?

    init(settingsService: SettingsService = .shared) {
        self.settingsService = settingsService
        self.selectedLevel = settingsService.logLevel
    }

    deinit {
        refreshTask?.cancel()
    }

    var filteredEntries: [LogEntry] {
        let threshold = Date().addingTimeInterval(-recentWindow)
        return entries.filter { entry in
            entry.level.rank >= selectedLevel.rank &&
            (selectedSource == .all || selectedSource == entry.source) &&
            (!showRecentOnly || entry.timestamp == nil || entry.timestamp! >= threshold)
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: refreshIntervalNs)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func clear() {
        SharedLogSink.shared.clear()
        TunnelDiagnosticsStore.shared.clear()
        entries = []
    }

    func saveLogLevel(_ level: LogLevel) {
        selectedLevel = level
        Task {
            await settingsService.setLogLevel(level)
            await VPNService.pushLogLevelToActiveTunnel(level)
        }
    }

    func exportFilteredText() -> String {
        let logText = filteredEntries.map(\.raw).joined(separator: "\n")
        let diagnosticsText = TunnelDiagnosticsStore.shared.exportDiagnosticsText()
        return redactSensitive([logText, diagnosticsText].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    private func refresh() {
        let text = SharedLogSink.shared.readAll()
        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        entries = lines.enumerated().map { index, line in
            let source: SourceFilter
            if line.contains("[org.fptn.tunnel]") {
                source = .tunnel
            } else {
                source = .app
            }

            return LogEntry(
                id: index,
                raw: line,
                level: levelFor(line: line),
                source: source,
                timestamp: parseTimestamp(line)
            )
        }
    }

    private func parseTimestamp(_ line: String) -> Date? {
        guard let firstSpace = line.firstIndex(of: " ") else { return nil }
        let ts = String(line[..<firstSpace])
        return ISO8601DateFormatter().date(from: ts)
    }

    private func levelFor(line: String) -> LogLevel {
        if line.contains("🔍") || line.contains("🐛") {
            return .debug
        }
        if line.contains("ℹ️") || line.contains("📝") {
            return .info
        }
        if line.contains("⚠️") || line.contains("❌") || line.contains("💥") {
            return .warning
        }
        return .info
    }

    private func redactSensitive(_ input: String) -> String {
        var text = input

        let patterns: [(String, String)] = [
            (#"(?i)(access[_-]?token\"?\s*[:=]\s*\"?)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(password\"?\s*[:=]\s*\"?)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(authorization\"?\s*[:=]\s*\"?bearer\s+)([^\",\s]+)"#, "$1<redacted>"),
            (#"(?i)(token\"?\s*[:=]\s*\"?)([^\",\s]{8,})"#, "$1<redacted>")
        ]

        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }

        return text
    }
}

private extension LogLevel {
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        }
    }
}

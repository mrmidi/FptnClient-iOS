/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Collections

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
    @Published private(set) var entries = Deque<LogEntry>()
    @Published var isFollowing = true

    private let settingsService: SettingsService
    private let recentWindow: TimeInterval = 24 * 60 * 60
    private let refreshIntervalNs: UInt64 = 1_000_000_000
    private var refreshTask: Task<Void, Never>?

    private var lastAppOffset: UInt64 = 0
    private var lastTunnelOffset: UInt64 = 0
    private var nextEntryId = 0

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
        RingLogSink.app.clear()
        RingLogSink.tunnel.clear()
        TunnelDiagnosticsStore.shared.clear()
        entries.removeAll()
        lastAppOffset = 0
        lastTunnelOffset = 0
        nextEntryId = 0
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
        var newEntries: [LogEntry] = []

        // 1. Read new App logs
        if let (appData, nextAppOffset) = RingLogSink.app.readNewBytes(from: lastAppOffset) {
            if nextAppOffset < lastAppOffset {
                entries.removeAll()
                nextEntryId = 0
                lastTunnelOffset = 0
            }
            lastAppOffset = nextAppOffset
            if !appData.isEmpty, let text = String(data: appData, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                for line in lines {
                    newEntries.append(LogEntry(
                        id: nextEntryId,
                        raw: line,
                        level: levelFor(line: line),
                        source: .app,
                        timestamp: parseTimestamp(line)
                    ))
                    nextEntryId += 1
                }
            }
        }

        // 2. Read new Tunnel logs
        if let (tunnelData, nextTunnelOffset) = RingLogSink.tunnel.readNewBytes(from: lastTunnelOffset) {
            if nextTunnelOffset < lastTunnelOffset {
                entries.removeAll()
                nextEntryId = 0
                lastAppOffset = 0
            }
            lastTunnelOffset = nextTunnelOffset
            if !tunnelData.isEmpty, let text = String(data: tunnelData, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                for line in lines {
                    newEntries.append(LogEntry(
                        id: nextEntryId,
                        raw: line,
                        level: levelFor(line: line),
                        source: .tunnel,
                        timestamp: parseTimestamp(line)
                    ))
                    nextEntryId += 1
                }
            }
        }

        // 3. Merge, sort and trim
        if !newEntries.isEmpty {
            entries.append(contentsOf: newEntries)
            
            // Sort chronologically by timestamp
            entries.sort { (a, b) -> Bool in
                guard let ta = a.timestamp, let tb = b.timestamp else {
                    return a.id < b.id
                }
                if ta == tb {
                    return a.id < b.id
                }
                return ta < tb
            }

            // Trim to max 500 lines for this phase
            if entries.count > 500 {
                entries.removeFirst(entries.count - 500)
            }
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

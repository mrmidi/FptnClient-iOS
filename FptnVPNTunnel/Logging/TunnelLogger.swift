/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Logging
import OSLog

private enum TunnelRuntimeLogLevel: String {
    case warning
    case info
    case debug

    var loggingLevel: Logging.Logger.Level {
        switch self {
        case .warning: return .warning
        case .info: return .info
        case .debug: return .debug
        }
    }

    static func from(loggingLevel: Logging.Logger.Level) -> TunnelRuntimeLogLevel {
        switch loggingLevel {
        case .critical, .error, .warning:
            return .warning
        case .notice, .info:
            return .info
        case .debug, .trace:
            return .debug
        }
    }
}

private final class TunnelLoggingBootstrapState: @unchecked Sendable {
    static let shared = TunnelLoggingBootstrapState()

    private let lock = NSLock()
    private var hasBootstrapped = false

    func bootstrapIfNeeded(_ bootstrap: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasBootstrapped else { return }
        bootstrap()
        hasBootstrapped = true
    }
}

private final class TunnelLogLevelStore: @unchecked Sendable {
    static let shared = TunnelLogLevelStore()

    private let lock = NSLock()
    private var current: TunnelRuntimeLogLevel = .info

    func get() -> TunnelRuntimeLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(rawValue: String?) {
        guard let rawValue, let level = TunnelRuntimeLogLevel(rawValue: rawValue) else { return }
        set(level)
    }

    func set(_ level: TunnelRuntimeLogLevel) {
        lock.lock()
        current = level
        lock.unlock()
    }
}

// MARK: - Module-level logger (tunnel target)

let logger = Logging.Logger(label: "org.fptn.tunnel")

// MARK: - Tunnel log system bootstrap

/// Call once from PacketTunnelProvider.startTunnel before any other code.
func bootstrapLogging() {
    TunnelLoggingBootstrapState.shared.bootstrapIfNeeded {
        LoggingSystem.bootstrap { label in
            TunnelLogHandler(label: label)
        }
    }
}

func setTunnelLogLevel(rawValue: String?) {
    TunnelLogLevelStore.shared.set(rawValue: rawValue)
}

// MARK: - TunnelLogHandler

/// Mirror of AppLogHandler for the tunnel extension process.
/// Writes to the same App Group log file and to os_log.
struct TunnelLogHandler: Logging.LogHandler {

    let label: String
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level {
        get { TunnelLogLevelStore.shared.get().loggingLevel }
        set { TunnelLogLevelStore.shared.set(TunnelRuntimeLogLevel.from(loggingLevel: newValue)) }
    }

    private let osLog: OSLog

    init(label: String) {
        self.label = label
        let category = label.components(separatedBy: ".").last ?? label
        self.osLog = OSLog(subsystem: "org.fptn", category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let text = format(level: level, message: message, file: file, line: line)

        // 1. os_log — attach Xcode to the FptnVPNTunnel process to see this
        let osType: OSLogType
        switch level {
        case .trace, .debug:    osType = .debug
        case .info, .notice:    osType = .info
        case .warning, .error:  osType = .error
        case .critical:         osType = .fault
        }
        os_log("%{public}@", log: osLog, type: osType, text)

        // 2. Shared App Group file — readable by the main app's DebugLogView
        SharedLogSink.shared.write(text)
    }

    private func format(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        file: String,
        line: UInt
    ) -> String {
        let fileName = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let emoji: String
        switch level {
        case .trace:    emoji = "🔍"
        case .debug:    emoji = "🐛"
        case .info:     emoji = "ℹ️"
        case .notice:   emoji = "📝"
        case .warning:  emoji = "⚠️"
        case .error:    emoji = "❌"
        case .critical: emoji = "💥"
        }
        return "\(emoji) [\(label)] \(fileName):\(line) \(message)"
    }
}

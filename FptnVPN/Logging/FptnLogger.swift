/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Logging
import OSLog

// MARK: - Module-level logger (app target)

let logger = Logging.Logger(label: "org.fptn.app")

// MARK: - Log system bootstrap

/// Call once from FptnVPNApp before any other code runs.
func bootstrapLogging() {
    LoggingSystem.bootstrap { label in
        AppLogHandler(label: label)
    }
}

// MARK: - AppLogHandler

/// Writes to:
///   1. os_log  – visible in Xcode console and Console.app (filter: subsystem "org.fptn")
///   2. Shared App Group log file – readable by DebugLogView and the tunnel process
struct AppLogHandler: Logging.LogHandler {

    let label: String
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = {
#if DEBUG
        return .debug
#else
        return .info
#endif
    }()

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

        // 1. os_log — appears in Xcode console when attached to this process
        let osType = level.osLogType
        os_log("%{public}@", log: osLog, type: osType, text)

        // 2. Shared file sink
        SharedLogSink.shared.write(text)
    }

    private func format(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        file: String,
        line: UInt
    ) -> String {
        let fileName = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let prefix = level.emoji
        return "\(prefix) [\(label)] \(fileName):\(line) \(message)"
    }
}

// MARK: - Logger.Level helpers

private extension Logging.Logger.Level {
    var osLogType: OSLogType {
        switch self {
        case .trace:   return .debug
        case .debug:   return .debug
        case .info:    return .info
        case .notice:  return .default
        case .warning: return .error
        case .error:   return .error
        case .critical: return .fault
        }
    }

    var emoji: String {
        switch self {
        case .trace:    return "🔍"
        case .debug:    return "🐛"
        case .info:     return "ℹ️"
        case .notice:   return "📝"
        case .warning:  return "⚠️"
        case .error:    return "❌"
        case .critical: return "💥"
        }
    }
}

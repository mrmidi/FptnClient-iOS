/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Logging

enum LogLevel: String, CaseIterable, Codable, Identifiable {
    case warning
    case info
    case debug

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .warning: return "Warning"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }

    var loggingLevel: Logging.Logger.Level {
        switch self {
        case .warning: return .warning
        case .info: return .info
        case .debug: return .debug
        }
    }

    static func from(loggingLevel: Logging.Logger.Level) -> LogLevel {
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

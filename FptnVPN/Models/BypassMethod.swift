/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

enum BypassMethod: String, CaseIterable, Codable {
    case sniSpoofing = "SNI"
    case obfuscation = "OBFUSCATION"
    case sniReality  = "SNI-REALITY"

    var displayName: String {
        switch self {
        case .sniSpoofing: return "SNI Spoofing"
        case .obfuscation: return "TLS Obfuscation"
        case .sniReality:  return "SNI + REALITY"
        }
    }

    /// Whether SNI hostname input is relevant for this method
    var requiresSNI: Bool { self != .obfuscation }
}

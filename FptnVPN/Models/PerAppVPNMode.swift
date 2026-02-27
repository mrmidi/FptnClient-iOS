/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

enum PerAppVPNMode: String, Codable {
    case off
    case onlyAllowed
    case exceptDisallowed
}

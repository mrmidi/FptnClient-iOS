/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

struct AppFilter: Codable, Identifiable {
    let bundleID: String
    let displayName: String
    var isSelected: Bool

    var id: String { bundleID }
}

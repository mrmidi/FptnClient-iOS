/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

// MARK: - Credential redaction

/// Returns the first `visible` characters followed by asterisks.
/// Used to safely log tokens, passwords, and fingerprints.
///
/// Example:
/// ```swift
/// logger.debug("token: \(hideCred(accessToken))")
/// // Output: "token: eyJh****"
/// ```
func hideCred(_ value: String, visible: Int = 4) -> String {
    guard !value.isEmpty else { return "****" }
    guard value.count > visible else {
        return String(repeating: "*", count: value.count)
    }
    return String(value.prefix(visible)) + String(repeating: "*", count: value.count - visible)
}

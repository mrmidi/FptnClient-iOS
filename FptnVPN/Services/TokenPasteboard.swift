/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import UIKit

/// Reads a token from the system clipboard.
///
/// Exists to tell two failures apart that `UIPasteboard.general.string` reports
/// identically as `nil`: the clipboard genuinely holding no text, and the user
/// declining iOS's "Allow Paste" prompt. Since paste is now the *only* way into
/// the app, telling someone to "copy the token first" when they actually just
/// tapped Don't Allow would leave them stuck following advice that cannot work.
enum TokenPasteboard {

    enum ReadFailure: LocalizedError, Equatable {
        /// No text on the clipboard at all.
        case empty
        /// Clipboard has text, but this process was not allowed to read it.
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .empty:
                return NSLocalizedString("Clipboard is empty — copy the token from @fptn_bot first", comment: "")
            case .accessDenied:
                return NSLocalizedString("Paste access was denied — tap again and choose Allow Paste", comment: "")
            }
        }
    }

    /// The clipboard's text, or a failure that says which of the two it was.
    ///
    /// `hasStrings` is a detection API and does **not** raise the paste prompt,
    /// so checking it first costs nothing and makes the distinction possible.
    static func readToken() throws -> String {
        let pasteboard = UIPasteboard.general

        guard pasteboard.hasStrings else { throw ReadFailure.empty }

        guard let value = pasteboard.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // `hasStrings` said yes but the read came back empty: the prompt was
            // declined, or the item vanished between the two calls.
            throw ReadFailure.accessDenied
        }

        return value
    }
}

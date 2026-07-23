/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import Foundation
import UIKit


private extension UIColor {
    static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

extension Color {
    static let appAccent = Color(red: 3 / 255.0, green: 218 / 255.0, blue: 197 / 255.0)

    // Backward-compatible aliases used throughout the app.
    static let cian = appAccent

    static let appBackground = Color(uiColor: .adaptive(
        light: UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1.0),
        dark: UIColor(red: 0x1B / 255.0, green: 0x02 / 255.0, blue: 0x3B / 255.0, alpha: 1.0)
    ))

    static let appSurface = Color(uiColor: .adaptive(
        light: UIColor(red: 0.99, green: 0.99, blue: 1.0, alpha: 1.0),
        dark: UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1.0)
    ))

    static let appElevatedSurface = Color(uiColor: .adaptive(
        light: UIColor.white,
        dark: UIColor(red: 0.24, green: 0.24, blue: 0.28, alpha: 1.0)
    ))

    static let appPrimaryText = Color(uiColor: .label)
    static let appSecondaryText = Color(uiColor: .secondaryLabel)
    static let appMutedControl = Color(uiColor: .tertiarySystemFill)
    static let appSeparator = Color(uiColor: .separator)
    static let appSuccess = Color(uiColor: .systemGreen)
    static let appWarning = Color(uiColor: .systemOrange)
    static let appError = Color(uiColor: .systemRed)
}


enum AppLinks {
    static let telegramBot = String("https://t.me/fptn_bot")
    static let website = String("https://fptn.org")
}

enum AppColorScheme: String, CaseIterable, Identifiable {
    case system = "system"
    case dark   = "dark"
    case light  = "light"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    /// Maps to SwiftUI's ColorScheme? (nil = follow system)
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

@main
struct FptnVPNApp: App {
    @AppStorage("fptn.settings.colorScheme") private var colorSchemeRaw = AppColorScheme.system.rawValue

    init() {
        // Bootstrap logging before any other code runs.
        // All subsequent logger.* calls go to os_log + shared log file.
        bootstrapLogging()
        logger.info("FptnVPN app started")

        // Start collecting crash/hang diagnostics via MetricKit.
        _ = MetricKitManager.shared
    }

    var body: some Scene {
        WindowGroup {
            LoginView()
                .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
        }
    }
}

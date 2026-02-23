/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

@main
struct FptnVPNApp: App {

    init() {
        // Bootstrap logging before any other code runs.
        // All subsequent logger.* calls go to os_log + shared log file.
        bootstrapLogging()
        logger.info("FptnVPN app started")
    }

    var body: some Scene {
        WindowGroup {
            LoginView()
        }
    }
}

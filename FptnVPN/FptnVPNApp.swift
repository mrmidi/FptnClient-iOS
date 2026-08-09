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
        RingLogSink.app.clear()
        RingLogSink.tunnel.clear()
        logger.info("FptnVPN app started")
        if NativeBuildInfo.isPerformanceRepresentative {
            logger.info("Build: \(NativeBuildInfo.logLine)")
        } else {
            logger.warning("Build: \(NativeBuildInfo.logLine)")
        }

        // Start collecting crash/hang diagnostics via MetricKit.
        // _ = MetricKitManager.shared

        // Begin observing iCloud KVS changes for cross-device token sync.
        TokenService.shared.startCloudSync()
    }

    var body: some Scene {
        WindowGroup {
            LoginView()
                .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
                .task { await Self.refreshGeoDatabaseIfNeeded() }
        }
    }

    /// Keeps the routing lists within a day of the publisher, who cuts a
    /// release roughly daily.
    ///
    /// Runs regardless of the selected data plane. Half a megabyte once a day
    /// is not worth reasoning about, and gating it on the current mode means
    /// the first switch to split routing is the slowest one — exactly when
    /// someone is least inclined to wait, and possibly already on the censored
    /// network that makes the download impossible.
    ///
    /// Failure is expected on a network that blocks the CDN and is handled
    /// inside `provision()` — it logs, keeps whatever is already published, and
    /// never interrupts launch.
    @MainActor
    private static func refreshGeoDatabaseIfNeeded() async {
        await GeoDatabaseStore.shared.provision()
    }
}

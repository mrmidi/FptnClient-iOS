/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

/// Provenance of the `fptn_native_lib` binary actually loaded into this
/// process, alongside the Swift target's own configuration.
///
/// This exists because the two can differ, silently and invisibly. A Release
/// Swift build happily links a Debug native framework: the app is optimised,
/// the entire protocol stack — websocket, yaff serialiser, lwIP — is not.
/// Nothing in Xcode, the logs, or the UI said so, and a CPU profile taken in
/// that state ranks its hot spots wrongly, because `-O0` inflates the
/// template-heavy layers far more than flat code.
///
/// The values come from `FPTNBuildInfo`, which is compiled into the framework
/// binary itself rather than read from `fptn_native_lib.build-manifest.json`.
/// The manifest is a sidecar: copy a framework between build directories by
/// hand and it describes a different build than the one that loaded.
public enum NativeBuildInfo {
    // MARK: Native framework

    /// CMake configuration of the native framework ("Debug", "Release", ...).
    public static var configuration: String { FPTNBuildInfo.configuration }

    /// Platform the framework was compiled for, from TargetConditionals.
    public static var platform: String { FPTNBuildInfo.platform }

    /// The -O class the framework was compiled with: "-O0", "-Os/-Oz", "-O1+".
    public static var optimizationLevel: String { FPTNBuildInfo.optimizationLevel }

    public static var isOptimized: Bool { FPTNBuildInfo.optimized }
    public static var assertionsEnabled: Bool { FPTNBuildInfo.assertionsEnabled }
    public static var isSimulator: Bool { FPTNBuildInfo.simulator }

    /// Short commit of the FptnLib/fptn submodule the framework was built from.
    public static var fptnCommit: String { FPTNBuildInfo.fptnCommit }

    public static var compiler: String { FPTNBuildInfo.compiler }
    public static var buildTimestamp: String { FPTNBuildInfo.buildTimestamp }

    /// One line describing the native framework, e.g.
    /// `Debug -O0 · ios-device · assertions on · fptn 3fb5ff6`.
    public static var nativeSummary: String { FPTNBuildInfo.summary }

    // MARK: Swift target

    /// Configuration of the Swift code in this process, which is compiled
    /// separately from the framework and can disagree with it.
    public static var swiftConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    // MARK: Measurement trust

    /// `false` when a performance measurement taken against this process
    /// cannot be trusted at face value.
    public static var isPerformanceRepresentative: Bool {
        FPTNBuildInfo.performanceRepresentative
    }

    /// Why a profile taken now would mislead, or `nil` when it would not.
    /// Phrased for a log line and for the settings screen.
    public static var performanceCaveat: String? {
        if !isOptimized {
            return "native framework is \(optimizationLevel) — profiles will "
                + "misrank hot spots, not just scale them"
        }
        if isSimulator {
            return "simulator build — networking and CPU scheduling differ from a device"
        }
        return nil
    }

    /// Whether the Swift target and the native framework were built at
    /// different optimisation settings. Not an error, but worth surfacing:
    /// it is the state that produced a Release-looking app with an
    /// unoptimised protocol stack.
    public static var hasMixedConfiguration: Bool {
        swiftConfiguration != configuration
    }

    /// The line both the app and the tunnel emit at startup.
    public static var logLine: String {
        var line = "native \(nativeSummary) | swift \(swiftConfiguration)"
        if hasMixedConfiguration {
            line += " | MIXED CONFIG"
        }
        if let caveat = performanceCaveat {
            line += " | NOT REPRESENTATIVE: \(caveat)"
        }
        return line
    }
}

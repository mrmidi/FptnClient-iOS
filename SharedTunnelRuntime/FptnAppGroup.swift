import Foundation

/// The App Group container shared by the app and its packet-tunnel extension.
///
/// A sandboxed macOS app's group identifier must carry the Team ID prefix
/// (`TEAMID.group.…`); iOS uses the bare identifier. Rather than hardcode the
/// team, the prefix is stamped into each bundle's Info.plist at build time from
/// `$(TeamIdentifierPrefix)` and the candidates are tried in turn — asking for a
/// group that is not in the caller's entitlements simply returns nil.
///
/// Resolution failure is silent by design in `FileManager`, and everything
/// downstream (shared logs, diagnostics, the flight recorder) degrades through
/// optional chaining. That means a wrong identifier takes out precisely the
/// instrumentation you would reach for to debug it, so resolve in one place.
enum FptnAppGroup {

    /// Portal-registered identifier. Unchanged across platforms; only the
    /// *local* entitlement form differs.
    static let baseIdentifier = "group.net.mrmidi.FptnVPN"

    /// Container for `baseIdentifier`, or nil if this bundle cannot reach it.
    static let containerURL: URL? = resolveContainerURL()

    private static func resolveContainerURL() -> URL? {
        let manager = FileManager.default
        #if os(macOS)
        if let prefix = teamIdentifierPrefix, !prefix.isEmpty,
           let url = manager.containerURL(
               forSecurityApplicationGroupIdentifier: prefix + baseIdentifier) {
            return url
        }
        #endif
        return manager.containerURL(forSecurityApplicationGroupIdentifier: baseIdentifier)
    }

    /// `$(TeamIdentifierPrefix)` as stamped into Info.plist — includes its
    /// trailing dot, e.g. `"F6YA6B56LR."`.
    private static var teamIdentifierPrefix: String? {
        Bundle.main.object(forInfoDictionaryKey: "FPTNTeamIdentifierPrefix") as? String
    }
}

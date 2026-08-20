/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedTunnel

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var sni: String
    @Published var autoConnect: Bool
    @Published var bypassMethod: BypassMethod
    @Published var reconnectEnabled: Bool
    @Published var maxReconnectAttempts: Int
    @Published var reconnectDelay: Int
    @Published var websocketIdleTimeoutSeconds: Int
    @Published var colorScheme: AppColorScheme
    @Published var logLevel: LogLevel
    @Published var routePushThroughTunnel: Bool
    @Published var customDnsEnabled: Bool
    @Published var customDnsIPv4: String
    @Published var flowDataPlaneEnabled: Bool
    @Published var dataPlaneMode: TunnelDataPlaneMode

    /// When the stored token was last written. `nil` for tokens saved before the
    /// app tracked this, and for that case the UI says "unknown" rather than
    /// inventing a date.
    @Published private(set) var tokenUpdatedAt: Date?

    /// Result of the most recent in-place token refresh, cleared when shown.
    @Published var tokenRefreshOutcome: TokenRefreshOutcome?
    @Published private(set) var isRefreshingToken = false

    /// Set only when split routing was selected and no usable geo database
    /// could be produced. A stale-but-working database is not a failure.
    @Published var geoProvisionFailure: GeoProvisionOutcome?
    @Published private(set) var isProvisioningGeoDatabase = false

    /// Set when a routing preference changed but the policy carrying it could
    /// not be rebuilt. Distinct from `geoProvisionFailure`: a usable database is
    /// still published and routing, so the traffic warning there would be
    /// wrong — what failed is only the new preference taking effect.
    @Published var geoPolicyRebuildFailed = false

    /// Why provisioning produced nothing, so the alert can give advice that
    /// applies. `nil` when there is no pending failure.
    var geoProvisionFailureReason: GeoProvisionFailureReason? {
        guard case .unavailable(let reason, _) = geoProvisionFailure else {
            return nil
        }
        return reason
    }

    var onLogout: (() -> Void)?

    private let settingsService: SettingsService
    private let tokenService: TokenService
    private let geoDatabaseStore: GeoDatabaseStore

    init(settingsService: SettingsService = .shared,
         tokenService: TokenService = .shared,
         geoDatabaseStore: GeoDatabaseStore = .shared,
         onLogout: (() -> Void)? = nil) {
        self.settingsService = settingsService
        self.tokenService = tokenService
        self.geoDatabaseStore = geoDatabaseStore
        self.onLogout = onLogout
        // Read synchronously via nonisolated getters — no await needed.
        self.sni = settingsService.sni
        self.autoConnect = settingsService.autoConnect
        self.bypassMethod = settingsService.bypassMethod
        self.reconnectEnabled = settingsService.reconnectEnabled
        self.maxReconnectAttempts = settingsService.maxReconnectAttempts
        self.reconnectDelay = settingsService.reconnectDelay
        self.websocketIdleTimeoutSeconds = settingsService.websocketIdleTimeoutSeconds
        self.colorScheme = settingsService.colorScheme
        self.logLevel = settingsService.logLevel
        self.routePushThroughTunnel = settingsService.routePushThroughTunnel
        self.customDnsEnabled = settingsService.customDnsEnabled
        self.customDnsIPv4 = settingsService.customDnsIPv4
        self.flowDataPlaneEnabled = settingsService.flowDataPlaneEnabled
        self.dataPlaneMode = settingsService.dataPlaneMode
        self.tokenUpdatedAt = tokenService.tokenUpdatedAt()
    }

    // MARK: - Token freshness

    /// How old a token may get before Settings suggests refreshing it.
    ///
    /// A guess, deliberately isolated to one constant: the right value depends
    /// on how often the bot rotates tokens and how often the server list
    /// changes, neither of which the client can observe.
    static let tokenStalenessThreshold: TimeInterval = 7 * 24 * 60 * 60

    /// Re-read on appear so a refresh performed elsewhere is reflected without
    /// rebuilding the view model.
    func refreshTokenAge() {
        tokenUpdatedAt = tokenService.tokenUpdatedAt()
    }

    /// Replace the stored token from the clipboard, in place.
    ///
    /// Deliberately does not log out: the whole point is that an expired token
    /// should not cost the user their session and force them back through the
    /// login screen. Servers and credentials are swapped underneath; an active
    /// tunnel keeps running on the old ones until the next connect.
    func pasteNewToken() async {
        guard !isRefreshingToken else { return }
        isRefreshingToken = true
        defer { isRefreshingToken = false }

        do {
            let clipboard = try TokenPasteboard.readToken()
            let token = try TokenDecoder.decode(clipboard)
            await tokenService.saveTokenData(token)
            refreshTokenAge()
            tokenRefreshOutcome = .updated(serverCount: token.servers.count)
            logger.info("Token refreshed in place, servers: \(token.servers.count)")
        } catch {
            tokenRefreshOutcome = .failed(error.localizedDescription)
            logger.error("Token refresh rejected: \(error.localizedDescription)")
        }
    }

    var tokenAgeIsUnknown: Bool { tokenUpdatedAt == nil }

    /// True once the token is older than the threshold. False when the age is
    /// unknown — an unknown age is not evidence of staleness, and treating it
    /// as such would flag every existing install on first launch after update.
    var tokenIsStale: Bool {
        guard let tokenUpdatedAt else { return false }
        return Date().timeIntervalSince(tokenUpdatedAt) > Self.tokenStalenessThreshold
    }

    /// Localized, human-readable age, e.g. "8 days ago". `nil` when unknown.
    ///
    /// Anything under a minute reads as "Just now": `RelativeDateTimeFormatter`
    /// renders a just-written timestamp as "in 0 seconds", which looks like a
    /// bug and points at the future for something that already happened.
    var tokenAgeDescription: String? {
        guard let tokenUpdatedAt else { return nil }
        let elapsed = Date().timeIntervalSince(tokenUpdatedAt)
        if elapsed < 60 {
            return NSLocalizedString("Just now", comment: "Token was updated moments ago")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: tokenUpdatedAt, relativeTo: Date())
    }

    /// Absolute date, shown alongside the relative age so the value stays
    /// meaningful for a token that is months old.
    var tokenUpdatedAtDescription: String? {
        guard let tokenUpdatedAt else { return nil }
        return tokenUpdatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func saveSni() {
        let sanitized = SettingsService.sanitizeSNI(sni)
        if sanitized != sni { sni = sanitized }
        Task { await settingsService.setSni(sanitized) }
    }

    func saveAutoConnect(_ value: Bool) {
        autoConnect = value
        Task { await settingsService.setAutoConnect(value) }
    }

    func saveBypassMethod(_ method: BypassMethod) {
        bypassMethod = method
        Task { await settingsService.setBypassMethod(method) }
    }

    func saveReconnectEnabled(_ value: Bool) {
        reconnectEnabled = value
        Task { await settingsService.setReconnectEnabled(value) }
    }

    func saveMaxReconnectAttempts(_ value: Int) {
        maxReconnectAttempts = value
        Task { await settingsService.setMaxReconnectAttempts(value) }
    }

    func saveReconnectDelay(_ value: Int) {
        reconnectDelay = value
        Task { await settingsService.setReconnectDelay(value) }
    }

    func saveWebsocketIdleTimeoutSeconds(_ value: Int) {
        websocketIdleTimeoutSeconds = value
        Task { await settingsService.setWebsocketIdleTimeoutSeconds(value) }
    }

    func saveColorScheme(_ scheme: AppColorScheme) {
        colorScheme = scheme
        Task { await settingsService.setColorScheme(scheme) }
    }

    func saveLogLevel(_ level: LogLevel) {
        logLevel = level
        Task {
            await settingsService.setLogLevel(level)
            await VPNService.pushLogLevelToActiveTunnel(level)
        }
    }

    /// Where push goes is compiled into the split-routing policy rather than
    /// checked while packets flow, so flipping this changes nothing for split
    /// routing until the policy is rebuilt. Rebuilding needs no download — the
    /// lists are already on disk, which matters because the network that makes
    /// this setting necessary is often the one that cannot reach the CDN.
    func saveRoutePushThroughTunnel(_ value: Bool) {
        routePushThroughTunnel = value
        Task {
            await settingsService.setRoutePushThroughTunnel(value)
            isProvisioningGeoDatabase = true
            let outcome = await geoDatabaseStore.recompilePolicy()
            isProvisioningGeoDatabase = false
            switch outcome {
            case .upToDate, .refreshed:
                break
            case .failedButUsable:
                // A database is still published and routing; it just does not
                // carry the preference that was just asked for.
                geoPolicyRebuildFailed = true
            case .unavailable:
                geoProvisionFailure = outcome
            }
        }
    }

    func saveCustomDnsEnabled(_ value: Bool) {
        customDnsEnabled = value
        Task { await settingsService.setCustomDnsEnabled(value) }
    }

    func saveCustomDnsIPv4(_ value: String) {
        customDnsIPv4 = value
        Task { await settingsService.setCustomDnsIPv4(value) }
    }

    func saveFlowDataPlaneEnabled(_ value: Bool) {
        flowDataPlaneEnabled = value
        Task { await settingsService.setFlowDataPlaneEnabled(value) }
    }

    /// Changing the data plane takes effect on the next connect: both planes
    /// are built at tunnel start, so switching while connected would mean
    /// tearing the session down anyway.
    ///
    /// Selecting split routing also provisions the geo database, because split
    /// routing without one is just the FPTN-only plane with extra steps — every
    /// flow falls to the default verdict and goes to the server.
    func saveDataPlaneMode(_ value: TunnelDataPlaneMode) {
        dataPlaneMode = value
        Task {
            await settingsService.setDataPlaneMode(value)
            guard value == .split else { return }
            isProvisioningGeoDatabase = true
            let outcome = await geoDatabaseStore.provision()
            isProvisioningGeoDatabase = false
            // Only interrupt when it actually changes what the person gets.
            // A stale-but-working database still routes.
            if case .unavailable = outcome {
                geoProvisionFailure = outcome
            }
        }
    }

    func logout() {
        Task { await tokenService.clearTokenData() }
        onLogout?()
    }

    func clearKeychain() {
        Task {
            guard let username = await tokenService.getTokenData()?.username else { return }
            KeychainHelper.deletePassword(account: username)
        }
    }
}

/// Outcome of an in-place token refresh, shown inline in Settings rather than
/// as an alert — the row the user just tapped is where they are looking.
enum TokenRefreshOutcome: Equatable {
    case updated(serverCount: Int)
    case failed(String)

    var isSuccess: Bool {
        if case .updated = self { return true }
        return false
    }
}

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

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

    var onLogout: (() -> Void)?

    private let settingsService: SettingsService
    private let tokenService: TokenService

    init(settingsService: SettingsService = .shared,
         tokenService: TokenService = .shared,
         onLogout: (() -> Void)? = nil) {
        self.settingsService = settingsService
        self.tokenService = tokenService
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

    func saveRoutePushThroughTunnel(_ value: Bool) {
        routePushThroughTunnel = value
        Task { await settingsService.setRoutePushThroughTunnel(value) }
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

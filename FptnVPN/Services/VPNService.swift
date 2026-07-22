/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Combine
import Darwin
@preconcurrency import NetworkExtension
import FptnSharedCore
import FptnSharedTunnel
import FptnServerSelection
import FptnConnectionOrchestration
import FptnNativeBootstrap

@MainActor
final class VPNService: ObservableObject {
    @Published var connection = VPNConnection()

    private var packetTunnelProvider: NETunnelProviderManager?
    private var tunnelStatusObserver: NSObjectProtocol?
    private var isUserInitiatedDisconnect: Bool = true
    private var activeCoordinator: (any ConnectionLifecycleCoordinating)?

    private let tokenService = TokenService.shared
    private let healthStore = FileBackedServerHealthStore(fileURL: URL(fileURLWithPath: "health.json"))

    // MARK: - Public

    func syncWithSystem() {
        Task { @MainActor in
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                guard let manager = managers.first else {
                    packetTunnelProvider = nil
                    clearConnectionState()
                    return
                }

                packetTunnelProvider = manager
                observeTunnelStatus(manager)
                syncTunnelStatus()
            } catch {
                logger.warning("syncWithSystem: failed to load preferences: \(error.localizedDescription)")
            }
        }
    }

    func connect() {
        Task {
            isUserInitiatedDisconnect = false
            await performConnect()
        }
    }

    func disconnect() {
        isUserInitiatedDisconnect = true
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = .stopping

        Task {
            if let activeCoordinator {
                await activeCoordinator.disconnect(reason: .userInitiated)
            } else {
                let tunnel = NETunnelController()
                await tunnel.stop(episodeID: ConnectionEpisodeID(), initiator: .appDisconnect)
            }
        }
    }

    static func pushLogLevelToActiveTunnel(_ level: LogLevel) async {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers?.first,
              let session = manager.connection as? NETunnelProviderSession,
              [.connected, .connecting, .reasserting].contains(manager.connection.status) else {
            return
        }

        let sharedLogLevel = SharedLogLevel(rawValue: level.rawValue)
        let msg = TunnelControlMessage(action: .setLogLevel, logLevel: sharedLogLevel)
        if let data = try? JSONEncoder().encode(msg) {
            try? await session.sendProviderMessage(data)
        }
    }

    func refreshCachedServerWarning() {
        // No-op
    }

    func formatConnectionTime() -> String {
        return connection.connectionDurationString
    }

    func formatSpeed(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB/s", mb)
    }

    // MARK: - Private Connect Flow

    private func performConnect() async {
        connection.isConnecting = true
        connection.isReconnecting = false
        connection.isWaitingForNetwork = false
        connection.errorMessage = nil
        connection.runtimeState = .starting

        defer {
            connection.isConnecting = false
            if !connection.isConnected && !connection.isReconnecting {
                connection.runtimeState = nil
            }
        }

        if !NetworkMonitor.shared.isConnected {
            connection.isWaitingForNetwork = true
            logger.info("No network available — waiting for connectivity")
            do {
                try await NetworkMonitor.shared.waitForConnectivity(timeout: 30)
                logger.info("Network ready, proceeding with connection")
            } catch {
                connection.isWaitingForNetwork = false
                connection.errorMessage = "No network connection"
                logger.warning("Network wait timeout — aborting connection")
                return
            }
            connection.isWaitingForNetwork = false
        }

        guard let tokenData = await tokenService.getTokenData() else {
            connection.errorMessage = "No token data available"
            logger.error("No token data available")
            return
        }

        let servers = await tokenService.getServers()
        guard !servers.isEmpty else {
            connection.errorMessage = "No servers available"
            logger.warning("No servers available")
            return
        }

        let settings = SettingsService.shared
        let bootstrapContext = BootstrapContext(
            networkClass: .wifi,
            sni: settings.sni,
            censorshipStrategy: FptnSharedCore.CensorshipStrategy(storedValue: settings.censorshipStrategy.rawValue),
            ipv6Available: true,
            tokenConfigurationID: UUID().uuidString
        )
        let credentials = Credentials(username: tokenData.username, password: tokenData.password)

        let bootstrapper = NativeServerBootstrapper { server, context in
            iOSNativeBootstrapClient(server: server, context: context)
        }
        let tunnelController = NETunnelController()

        let result: ConnectionStartResult

        switch connection.connectionMode {
        case .manual(let chosenServer):
            connection.selectedServer = chosenServer
            let deps = ManualConnectionDependencies(
                bootstrapper: bootstrapper,
                tunnelController: tunnelController
            )
            let coordinator = makeManualCoordinator(deps: deps)
            activeCoordinator = coordinator
            let request = ManualConnectionRequest(
                server: chosenServer,
                credentials: credentials,
                bootstrapContext: bootstrapContext
            )
            result = await coordinator.connect(request)

        case .auto:
            let selector = AutoServerSelector(
                healthStore: healthStore,
                bootstrapper: bootstrapper
            )
            let deps = AutoConnectionDependencies(
                selector: selector,
                tunnelController: tunnelController
            )
            let coordinator = makeAutoCoordinator(deps: deps)
            activeCoordinator = coordinator
            let request = AutoConnectionRequest(
                servers: servers,
                credentials: credentials,
                bootstrapContext: bootstrapContext
            )
            result = await coordinator.connect(request)
        }

        switch result {
        case .started(let episodeID):
            logger.info("Connection started successfully for episode \(episodeID.rawValue.uuidString)")
            connection.isConnected = true
            connection.isConnecting = false
        case .failed(let failure):
            logger.error("Connection failed: \(failure)")
            connection.errorMessage = "Connection failed: \(failure)"
            connection.isConnected = false
            connection.isConnecting = false
        case .cancelled:
            logger.info("Connection request cancelled")
            connection.isConnected = false
            connection.isConnecting = false
        }
    }

    // MARK: - Status observation

    private func observeTunnelStatus(_ manager: NETunnelProviderManager) {
        if let previous = tunnelStatusObserver {
            NotificationCenter.default.removeObserver(previous)
        }

        tunnelStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncTunnelStatus()
            }
        }
    }

    private func syncTunnelStatus() {
        guard let tunnelConnection = packetTunnelProvider?.connection else {
            clearConnectionState()
            return
        }

        let status = tunnelConnection.status
        logger.info("Tunnel status changed: \(status.rawValue)")

        switch status {
        case .connected:
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = false
        case .reasserting:
            connection.isConnected = true
            connection.isConnecting = false
            connection.isReconnecting = true
            connection.runtimeState = .reasserting
        case .connecting:
            connection.isConnected = false
            connection.isConnecting = true
            connection.isReconnecting = false
            connection.runtimeState = .starting
        case .disconnecting:
            connection.isConnected = false
            connection.isConnecting = false
            connection.isReconnecting = false
            connection.runtimeState = .stopping
        case .disconnected, .invalid:
            clearConnectionState()
        @unknown default:
            break
        }
    }

    private func clearConnectionState() {
        connection.isConnected = false
        connection.isConnecting = false
        connection.isReconnecting = false
        connection.runtimeState = nil
    }
}

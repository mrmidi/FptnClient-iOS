/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
@preconcurrency import NetworkExtension
import FptnSharedCore
import FptnSharedTunnel
import FptnConnectionOrchestration

@MainActor
public final class NETunnelController: TunnelControlling {
    private var activeEpisodeID: ConnectionEpisodeID?
    private var activeManager: NETunnelProviderManager?

    public init() {}

    public func start(
        episodeID: ConnectionEpisodeID,
        configuration: TunnelStartupConfigurationV1
    ) async -> Result<Void, TunnelStartError> {
        do {
            try configuration.validate()
        } catch {
            return .failure(.refused("Validation failed: \(error)"))
        }

        let encodedData: Data
        do {
            encodedData = try JSONEncoder().encode(configuration)
        } catch {
            return .failure(.refused("Encoding failed: \(error)"))
        }

        guard encodedData.count <= TunnelStartupConfigurationV1.maximumEncodedSize else {
            return .failure(.refused("Configuration size exceeds 64 KiB"))
        }

        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = existing.first ?? NETunnelProviderManager()

            let config = NETunnelProviderProtocol()
            config.serverAddress = "FptnVPN"
            config.providerBundleIdentifier = "net.mrmidi.FptnVPN.FptnVPNTunnel"
            config.providerConfiguration = [
                TunnelProviderConfigurationKey.startupV1: encodedData
            ]

            if #available(iOS 16.4, *), SettingsService.shared.routePushThroughTunnel {
                config.includeAllNetworks = true
                config.excludeAPNs = false
            }

            manager.protocolConfiguration = config
            manager.localizedDescription = "FPTN"
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()

            activeEpisodeID = episodeID
            activeManager = manager

            return .success(())
        } catch {
            return .failure(.refused(error.localizedDescription))
        }
    }

    public func stop(episodeID: ConnectionEpisodeID, initiator: TunnelStopInitiator) async {
        guard activeEpisodeID == episodeID, let manager = activeManager else { return }
        activeEpisodeID = nil
        activeManager = nil

        if let session = manager.connection as? NETunnelProviderSession {
            let msg = TunnelControlMessage(
                action: .prepareStop,
                initiator: initiator
            )
            if let data = try? JSONEncoder().encode(msg) {
                try? session.sendProviderMessage(data)
            }
        }
        manager.connection.stopVPNTunnel()
    }
}

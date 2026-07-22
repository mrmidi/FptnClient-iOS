/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnSharedTunnel
import FptnServerSelection
import FptnConnectionOrchestration

public final class BootstrapOnlyTunnelController: TunnelControlling, @unchecked Sendable {
    public init() {}

    public func start(
        episodeID: ConnectionEpisodeID,
        configuration: TunnelStartupConfigurationV1
    ) async -> Result<Void, TunnelStartError> {
        guard !configuration.serverHost.isEmpty else {
            return .failure(.refused("Empty server host"))
        }
        guard configuration.serverPort > 0 && configuration.serverPort <= 65535 else {
            return .failure(.refused("Invalid server port: \(configuration.serverPort)"))
        }
        guard !configuration.accessToken.isEmpty else {
            return .failure(.refused("Empty access token"))
        }
        guard !configuration.dnsIPv4.isEmpty else {
            return .failure(.refused("Empty DNS IPv4 configuration"))
        }

        print("[TunnelController] bootstrap completed for episode: \(episodeID.rawValue.uuidString)")
        print("[TunnelController] Target Server: \(configuration.serverHost):\(configuration.serverPort)")
        print("[TunnelController] DNS config: IPv4=\(configuration.dnsIPv4), IPv6=\(configuration.dnsIPv6 ?? "none")")
        print("[TunnelController] Censorship Strategy: \(configuration.censorshipStrategy)")

        return .success(())
    }

    public func stop(episodeID: ConnectionEpisodeID, initiator: TunnelStopInitiator) async {
        print("[TunnelController] stop tunnel called for episode: \(episodeID.rawValue.uuidString), initiator: \(initiator)")
    }
}

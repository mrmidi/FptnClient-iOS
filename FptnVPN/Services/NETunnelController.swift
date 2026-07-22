/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import NetworkExtension
import FptnSharedCore
import FptnSharedTunnel
import FptnConnectionOrchestration

public final class NETunnelController: TunnelControlling, @unchecked Sendable {
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

        return await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { existing, error in
                if let error {
                    continuation.resume(returning: .failure(.refused(error.localizedDescription)))
                    return
                }

                let manager = existing?.first ?? NETunnelProviderManager()
                let config = NETunnelProviderProtocol()
                config.serverAddress = "FptnVPN"
                config.providerBundleIdentifier = "net.mrmidi.FptnVPN.FptnVPNTunnel"

                var providerConfiguration: [String: Any] = [
                    TunnelProviderConfigurationKey.startupV1: encodedData.base64EncodedString(),
                    // Backward-compatible fallback keys
                    "server": configuration.serverHost,
                    "port": configuration.serverPort,
                    "accessToken": configuration.accessToken,
                    "dnsIPv4": configuration.dnsIPv4,
                    "sni": configuration.sni,
                    "md5Fingerprint": configuration.md5Fingerprint,
                    "logLevel": configuration.logLevel.rawValue,
                    "websocketIdleTimeoutSeconds": configuration.websocketIdleTimeoutSeconds
                ]
                if let dnsIPv6 = configuration.dnsIPv6 {
                    providerConfiguration["dnsIPv6"] = dnsIPv6
                }
                if let customDns = configuration.customDnsIPv4 {
                    providerConfiguration["customDnsIPv4"] = customDns
                }

                config.providerConfiguration = providerConfiguration

                if #available(iOS 16.4, *), SettingsService.shared.routePushThroughTunnel {
                    config.includeAllNetworks = true
                    config.excludeAPNs = false
                }

                manager.protocolConfiguration = config
                manager.localizedDescription = "FPTN"
                manager.isEnabled = true

                manager.saveToPreferences { error in
                    if let error {
                        continuation.resume(returning: .failure(.refused(error.localizedDescription)))
                        return
                    }

                    manager.loadFromPreferences { error in
                        if let error {
                            continuation.resume(returning: .failure(.refused(error.localizedDescription)))
                            return
                        }

                        do {
                            try manager.connection.startVPNTunnel()
                            continuation.resume(returning: .success(()))
                        } catch {
                            continuation.resume(returning: .failure(.refused(error.localizedDescription)))
                        }
                    }
                }
            }
        }
    }

    public func stop(episodeID: ConnectionEpisodeID, initiator: TunnelStopInitiator) async {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers?.first else { return }

        if let session = manager.connection as? NETunnelProviderSession {
            let msg = TunnelControlMessage(
                action: .prepareStop,
                initiator: initiator
            )
            if let data = try? JSONEncoder().encode(msg) {
                try? await session.sendProviderMessage(data)
            }
        }
        manager.connection.stopVPNTunnel()
    }
}

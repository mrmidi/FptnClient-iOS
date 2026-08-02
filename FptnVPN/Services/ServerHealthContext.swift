/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import CryptoKit
import Foundation
import FptnSharedCore
import FptnServerSelection

/// Single source of truth for the server-health store and the context used to
/// key it.
///
/// Health records are scoped by network class, SNI, censorship strategy and
/// token configuration, so a reader that rebuilds the key differently silently
/// finds nothing. Both the connect path (`VPNService`) and the server list
/// (`ServerListViewModel`) go through here so the two cannot drift.
enum ServerHealthContext {
    static func makeStore() -> FileBackedServerHealthStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FptnVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileBackedServerHealthStore(fileURL: directory.appendingPathComponent("server-health.json"))
    }

    static func makeContext(
        tokenUsername: String,
        servers: [VPNServer],
        settings: SettingsService
    ) -> BootstrapContext {
        BootstrapContext(
            networkClass: .wifi,
            sni: settings.sni,
            censorshipStrategy: FptnSharedCore.CensorshipStrategy(
                storedValue: settings.censorshipStrategy.rawValue
            ),
            ipv6Available: false,
            tokenConfigurationID: configurationID(tokenUsername: tokenUsername, servers: servers)
        )
    }

    static func keys(for servers: [VPNServer], context: BootstrapContext) -> [ServerHealthKey] {
        servers.map { server in
            ServerHealthKey(
                serverID: server.id,
                networkClass: context.networkClass,
                sni: context.sni,
                censorshipStrategy: context.censorshipStrategy,
                ipv6Available: context.ipv6Available,
                tokenConfigurationID: context.tokenConfigurationID
            )
        }
    }

    static func configurationID(tokenUsername: String, servers: [VPNServer]) -> String {
        let canonicalServers = servers
            .map { "\($0.host):\($0.port):\($0.md5Fingerprint):\($0.name)" }
            .sorted()
            .joined(separator: "|")
        let material = "\(tokenUsername)|\(canonicalServers)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ServerLatencyRecord {
    /// Projects a persisted health record onto the row model the server list
    /// renders. Health records aggregate outcomes rather than storing the last
    /// one, so `.timeout` and `.unreachable` collapse into `.unreachable`.
    init?(health record: ServerHealthRecord) {
        let checkedAt = record.lastSuccessAt ?? record.lastFailureAt
        guard let checkedAt else { return nil }

        let latencyMs = record.ewmaLatencyMs.map { Int($0.rounded()) }
        let healthy = record.consecutiveFailures == 0 && latencyMs != nil

        self.init(
            serverID: record.key.serverID,
            state: healthy ? .reachable : .unreachable,
            latencyMs: healthy ? latencyMs : nil,
            detail: healthy
                ? "\(latencyMs ?? 0) ms"
                : "\(record.consecutiveFailures) failed attempt(s)",
            checkedAt: checkedAt.timeIntervalSince1970
        )
    }
}

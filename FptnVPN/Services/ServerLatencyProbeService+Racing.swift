/*=============================================================================
Copyright (c) 2026 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

extension ServerLatencyProbeService {
    
    /// Partitions servers: selects 100% of premium servers and a shuffled 50% sample of regular servers.
    static func selectCandidatesForTesting(servers: [VPNServer]) -> [VPNServer] {
        let premiumServers = servers.filter { $0.name.lowercased().contains("premium") }
        let regularServers = servers.filter { !$0.name.lowercased().contains("premium") }.shuffled()
        
        let regularCount = Int(ceil(Double(regularServers.count) * 0.5))
        return premiumServers + regularServers.prefix(regularCount)
    }
    
    /// Concurrently probes candidates and returns the first server that successfully
    /// completes the handshake and HTTP API verification. Cooperatively cancels remaining requests.
    func raceServerHandshakes(
        servers: [VPNServer],
        config: ServerLatencyProbeConfig = .default,
        probeBlock: @Sendable @escaping (VPNServer) async -> ServerLatencyProbeResult? = { server in
            let settings = SettingsService.shared
            let client = ApiClientBridge(
                host: server.host,
                port: server.port,
                sni: settings.sni,
                md5Fingerprint: server.md5_fingerprint,
                censorshipStrategy: settings.censorshipStrategy.rawValue
            )
            
            // Run TCP/TLS handshake
            let handshake = client.testHandshake(timeout: 5)
            guard handshake.reachable else { return nil }
            
            // Cooperative cancellation check before performing HTTP request
            guard !Task.isCancelled else { return nil }
            
            // Run HTTP request
            let dns = client.get(path: "/api/v1/dns", timeout: 5)
            guard dns.error == nil || dns.error?.isEmpty == true else { return nil }
            
            return ServerLatencyProbeResult(
                server: server,
                state: .reachable,
                latencyMs: handshake.latencyMs,
                detail: "verified_http_\(dns.code)",
                checkedAt: Date().timeIntervalSince1970
            )
        }
    ) async -> ServerLatencyProbeResult? {
        guard !servers.isEmpty else { return nil }
        
        // 1. Partition servers
        let candidates = Self.selectCandidatesForTesting(servers: servers)
        guard !candidates.isEmpty else { return nil }
        
        // 2. Race the candidates using structured concurrency
        return await withTaskGroup(of: ServerLatencyProbeResult?.self) { group in
            for server in candidates {
                group.addTask {
                    // Cooperative cancellation check before connection start
                    guard !Task.isCancelled else { return nil }
                    return await probeBlock(server)
                }
            }
            
            // Collect the first successful result and cancel all other tasks in the group
            for await result in group {
                if let winner = result {
                    group.cancelAll()
                    return winner
                }
            }
            
            return nil
        }
    }
}

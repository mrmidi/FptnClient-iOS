/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import OSLog
import FptnSharedCore
import FptnServerSelection

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

    /// Concurrently logs into candidates and returns the first server that successfully
    /// completes both authentication and bootstrap DNS configuration fetching.
    /// Cooperatively cancels remaining requests using a concurrency-limited sliding window.
    func raceServerLogins(
        servers: [VPNServer],
        tokenData: FPTNToken,
        config: ServerLatencyProbeConfig = .default
    ) async -> ServerLoginRaceResult? {
        let logger = Logger(subsystem: "net.mrmidi.FptnVPN", category: "ServerLatencyProbeService")
        logger.info("Auto Mode race starting for \(servers.count) servers")
        
        // 1. Select and partition candidates
        let candidates = Self.selectCandidatesForTesting(servers: servers)
        guard !candidates.isEmpty else {
            logger.warning("No candidates available for testing after partitioning.")
            return nil
        }
        
        // 2. Sort candidate list by cache rank/latency before running the race!
        let latencyCache = ServerLatencyCacheService.shared
        let records = await latencyCache.freshRecords()
        
        let sortedCandidates = candidates.sorted { s1, s2 in
            let r1 = records[s1.id]
            let r2 = records[s2.id]
            
            let rank1 = r1?.state.sortRank ?? 1
            let rank2 = r2?.state.sortRank ?? 1
            
            if rank1 != rank2 {
                return rank1 < rank2
            }
            
            let lat1 = r1?.latencyMs ?? 1000
            let lat2 = r2?.latencyMs ?? 1000
            
            if lat1 != lat2 {
                return lat1 < lat2
            }
            
            return s1.name.localizedCaseInsensitiveCompare(s2.name) == .orderedAscending
        }
        
        logger.info("Candidates sorted by cache rank. Running race for \(sortedCandidates.count) servers.")
        
        // 3. Configure credentials and probe context
        let credentials = Credentials(username: tokenData.username, password: tokenData.password)
        let settings = SettingsService.shared
        let context = ProbeContext(
            networkClass: .wifi, // Fallback network class
            sni: settings.sni,
            censorshipStrategy: FptnSharedCore.CensorshipStrategy(storedValue: settings.censorshipStrategy.rawValue),
            ipv6Available: false,
            tokenConfigurationID: "token_config_digest"
        )
        
        let nativeProbe = NativeServerBootstrapProbe()
        let race = SlidingWindowRace()
        
        // 4. Run the bounded sliding-window connection race
        let result = await race.run(
            candidates: sortedCandidates,
            credentials: credentials,
            context: context,
            limit: 4, // Maximum active concurrent probes
            timeout: .seconds(5),
            overallTimeout: .seconds(15),
            probe: nativeProbe
        )
        
        switch result {
        case .success(let winner):
            logger.info("Race won by server: \(winner.server.name) in \(winner.metrics.totalMs)ms. Access token and DNS obtained.")
            
            // Map the FPTNServerSelection models to FptnVPN models
            let probeResult = ServerLatencyProbeResult(
                server: winner.server,
                state: .reachable,
                latencyMs: winner.metrics.fakeHandshakeMs,
                detail: "verified_login_200",
                checkedAt: Date().timeIntervalSince1970
            )
            
            // Dynamically save the DNS configurations returned from bootstrap race into state if needed.
            // Note: VPNService.swift reads this winnerResult.accessToken and starts connection.
            // Since we fetched DNS configurations during race, we will cache/store them or return them!
            // Wait, we need to pass the fetched DNS values to VPNService!
            // Let's check: does ServerLoginRaceResult support returning dnsIPv4 / dnsIPv6?
            // Let's check how ServerLoginRaceResult is defined:
            // struct ServerLoginRaceResult: Sendable {
            //     let probeResult: ServerLatencyProbeResult
            //     let accessToken: String
            // }
            // If we add optional dnsIPv4/dnsIPv6 to ServerLoginRaceResult, we can avoid querying /api/v1/dns again in VPNService!
            return ServerLoginRaceResult(
                probeResult: probeResult,
                accessToken: winner.accessToken,
                dnsIPv4: winner.dnsIPv4,
                dnsIPv6: winner.dnsIPv6
            )
            
        case .allCandidatesFailed(let summary):
            logger.warning("Race finished: all candidates failed. Attempted: \(summary.attemptedCount). Errors by kind: \(summary.failuresByKind)")
            return nil
            
        case .cancelled:
            logger.warning("Race cancelled or hit overall 30-second timeout.")
            return nil
            
        @unknown default:
            logger.error("Unknown selection result case encountered.")
            return nil
        }
    }
}

struct ServerLoginRaceResult: Sendable {
    let probeResult: ServerLatencyProbeResult
    let accessToken: String
    let dnsIPv4: String?
    let dnsIPv6: String?
    
    init(probeResult: ServerLatencyProbeResult, accessToken: String, dnsIPv4: String? = nil, dnsIPv6: String? = nil) {
        self.probeResult = probeResult
        self.accessToken = accessToken
        self.dnsIPv4 = dnsIPv4
        self.dnsIPv6 = dnsIPv6
    }
}

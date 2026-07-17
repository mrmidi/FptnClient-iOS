/*=============================================================================
Copyright (c) 2026 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import OSLog

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
    /// authenticates and provides an access token. Cooperatively cancels remaining requests.
    /// Incorporates a 30-second global timeout using GCD.
    func raceServerLogins(
        servers: [VPNServer],
        tokenData: FPTNToken,
        config: ServerLatencyProbeConfig = .default,
        loginBlock: @Sendable @escaping (VPNServer, FPTNToken) async -> ServerLoginRaceResult? = { server, tokenData in
            let logger = Logger(subsystem: "net.mrmidi.FptnVPN", category: "ServerLatencyProbeService")
            logger.info("Probe starting for server \(server.name) (host=\(server.host))")
            
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
            guard handshake.reachable else {
                logger.warning("Probe handshake failed for server \(server.name): \(handshake.error ?? "unknown error")")
                return nil
            }
            
            // Cooperative cancellation check before performing login request
            guard !Task.isCancelled else {
                logger.info("Probe cancelled for server \(server.name) before login")
                return nil
            }
            
            // Run login request
            let requestBody = """
            {
                "username": "\(tokenData.username)",
                "password": "\(tokenData.password)"
            }
            """
            
            let response = client.post(
                path: "/api/v1/login",
                body: requestBody,
                timeout: 5
            )
            
            guard response.code == 200 else {
                logger.warning("Probe login failed for server \(server.name) code=\(response.code) error=\(response.error ?? "none") body=\(response.body ?? "empty")")
                return nil
            }
            
            guard let body = response.body,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                logger.warning("Probe login response parse failed for server \(server.name)")
                return nil
            }
            
            logger.info("Probe successfully logged in for server \(server.name) with latency \(handshake.latencyMs ?? 0)ms")
            
            let probeResult = ServerLatencyProbeResult(
                server: server,
                state: .reachable,
                latencyMs: handshake.latencyMs,
                detail: "verified_login_200",
                checkedAt: Date().timeIntervalSince1970
            )
            
            return ServerLoginRaceResult(probeResult: probeResult, accessToken: accessToken)
        }
    ) async -> ServerLoginRaceResult? {
        guard !servers.isEmpty else { return nil }
        
        let candidates = Self.selectCandidatesForTesting(servers: servers)
        guard !candidates.isEmpty else { return nil }
        
        let raceTask = Task {
            await withTaskGroup(of: ServerLoginRaceResult?.self, returning: ServerLoginRaceResult?.self) { group in
                for server in candidates {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await loginBlock(server, tokenData)
                    }
                }
                
                for await result in group {
                    if let winner = result {
                        group.cancelAll()
                        return winner
                    }
                }
                
                return nil
            }
        }
        
        // Schedule a timeout using GCD to cooperatively cancel the Task
        let timeoutWorkItem = DispatchWorkItem {
            raceTask.cancel()
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 30.0, execute: timeoutWorkItem)
        
        let result = await raceTask.value
        timeoutWorkItem.cancel()
        
        return result
    }
}

struct ServerLoginRaceResult: Sendable {
    let probeResult: ServerLatencyProbeResult
    let accessToken: String
}

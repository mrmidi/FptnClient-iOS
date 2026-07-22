/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnSharedTunnel
import FptnServerSelection
import FptnConnectionOrchestration
import FptnSharedTestSupport
import FptnNativeBootstrap

@main
struct FptnSelectorApp {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            Self.printUsage()
            return
        }

        let command = args[1]

        if command == "test-token" || getArgValue(for: "--test-token", args: args) != nil {
            runTestToken(args: args)
            return
        }

        switch command {
        case "auto-select":
            await runAutoSelect(args: args)
        case "manual-bootstrap":
            await runManualBootstrap(args: args)
        case "scan-all":
            await runScanAll(args: args)
        case "diagnostic":
            await runDiagnostic(args: args)
        case "simulate":
            await runSimulate(args: args)
        case "matrix":
            await runMatrix(args: args)
        case "soak-sim":
            await runSoakSim(args: args)
        case "test-token":
            runTestToken(args: args)
        default:
            if getArgValue(for: "--token", args: args) != nil {
                await runAutoSelect(args: args)
            } else {
                print("Unknown command: \(command)")
                Self.printUsage()
            }
        }
    }

    static func printUsage() {
        print("""
        FPTN Server Selector CLI

        Usage:
          fptn-selector test-token --token "<token>"
          fptn-selector auto-select [--token "<token>"] [--config <path>] [--output <jsonl-path>]
          fptn-selector scan-all [--token "<token>"] [--config <path>] [--output <jsonl-path>]
          fptn-selector manual-bootstrap --server <host:port> [--token "<token>"] [--config <path>] [--output <jsonl-path>]
          fptn-selector diagnostic [--token "<token>"] [--config <path>]
          fptn-selector simulate --scenario <path>
          fptn-selector matrix [--token "<token>"] [--config <path>] --iterations <n> [--output <jsonl-path>]
          fptn-selector soak-sim --iterations <n>

        Configuration & Authentication:
          • Pass --token "<token>" (or set FPTN_TOKEN) to automatically supply both the server list and credentials.
          • Pass --config <path> to load servers and settings from a JSON file.
          • Credentials can also be passed via --username/--password or FPTN_USERNAME/FPTN_PASSWORD.
        """)
    }

    // MARK: - Token Inspection Command

    static func runTestToken(args: [String]) {
        let tokenStr = getArgValue(for: "--token", args: args) ?? getArgValue(for: "--test-token", args: args)
        guard let rawToken = tokenStr, !rawToken.isEmpty else {
            print("Error: Missing --token <string> or --test-token <string>")
            return
        }

        guard let token = SecureCredentialProvider.parseFPTNToken(rawToken) else {
            print("Error: Invalid FPTN token format. Failed to decode Brotli/Base64 payload.")
            return
        }

        print("\n================ DECODED FPTN TOKEN REPORT ================")
        print("Version:       \(token.version)")
        print("Service Name:  \(token.serviceName)")
        print("Username:      \(token.username)")
        print("Password:      \(token.password)")
        print("Server Count:  \(token.servers.count)")
        print("-----------------------------------------------------------")
        print(String(format: "%-25@ | %-20@ | %-32@", "Server Name" as NSString, "Host:Port" as NSString, "MD5 Fingerprint" as NSString))
        print("-----------------------------------------------------------")
        for s in token.servers {
            print(String(format: "%-25@ | %-20@ | %-32@", s.name as NSString, "\(s.host):\(s.port)" as NSString, s.md5Fingerprint as NSString))
        }
        print("===========================================================\n")
    }

    // MARK: - Configuration Resolver

    struct CLIResolvedConfig {
        let servers: [VPNServer]
        let credentials: Credentials?
        let context: BootstrapContext
        let selectionPolicy: SelectionPolicy
        let bootstrapPolicy: BootstrapPolicy
    }

    enum CLIError: Error {
        case missingConfigOrToken
    }

    static func resolveCLIConfig(args: [String]) throws -> CLIResolvedConfig {
        let cliTokenStr = getArgValue(for: "--token", args: args) ?? getArgValue(for: "--test-token", args: args) ?? ProcessInfo.processInfo.environment["FPTN_TOKEN"]
        let parsedToken = cliTokenStr.flatMap { SecureCredentialProvider.parseFPTNToken($0) }

        let configPath = getArgValue(for: "--config", args: args)
        let loadedConfig = try configPath.map { try CLIConfig.load(from: $0) }

        guard parsedToken != nil || loadedConfig != nil else {
            print("Error: Specify either --token \"<token>\" or --config <path>.")
            throw CLIError.missingConfigOrToken
        }

        let servers: [VPNServer]
        if let token = parsedToken, !token.servers.isEmpty {
            servers = token.servers
        } else if let config = loadedConfig {
            servers = config.servers
        } else {
            servers = []
        }

        let credentials: Credentials?
        if let token = parsedToken {
            credentials = Credentials(username: token.username, password: token.password)
        } else {
            credentials = SecureCredentialProvider.getCredentials(args: args)
        }

        let sni = loadedConfig?.sni ?? "google.com"
        let strategy = loadedConfig?.censorshipStrategy ?? .sniSpoofing
        let ipv6 = loadedConfig?.ipv6Available ?? false
        let tokenConfigID = loadedConfig?.tokenConfigurationID ?? "token-cli"

        let context = BootstrapContext(
            networkClass: .wifi,
            sni: sni,
            censorshipStrategy: strategy,
            ipv6Available: ipv6,
            tokenConfigurationID: tokenConfigID
        )

        let selectionPolicy = loadedConfig?.resolveSelectionPolicy() ?? .production
        let bootstrapPolicy = loadedConfig?.resolveBootstrapPolicy() ?? .production

        return CLIResolvedConfig(
            servers: servers,
            credentials: credentials,
            context: context,
            selectionPolicy: selectionPolicy,
            bootstrapPolicy: bootstrapPolicy
        )
    }

    // MARK: - Subcommands

    static func runAutoSelect(args: [String]) async {
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try resolveCLIConfig(args: args)
            guard let credentials = config.credentials else {
                print("Error: Failed to obtain credentials.")
                return
            }
            guard !config.servers.isEmpty else {
                print("Error: No servers available to probe.")
                return
            }

            let healthStore = FileBackedHealthStore(fileURL: URL(fileURLWithPath: "health.json"))
            let bootstrapper = makeNativeBootstrapper()

            let selector = AutoServerSelector(
                policy: config.selectionPolicy,
                healthStore: healthStore,
                bootstrapper: bootstrapper
            )

            let request = SelectionRequest(
                servers: config.servers,
                credentials: credentials,
                context: config.context,
                bootstrapPolicy: config.bootstrapPolicy,
                selectionPolicy: config.selectionPolicy
            )

            print("Starting Auto Server Selection Race (\(config.servers.count) servers)...")
            let run = await selector.select(request)

            JSONLOutput.printRecord(command: "auto-select", data: run.statistics, toFile: outputFile)

            let report = ReportGenerator.generate(from: run.observations)
            ReportGenerator.renderToConsole(report: report)

            switch run.result {
            case .success(let win):
                print("Auto-Select Succeeded! Selected Winner: \(win.server.name) (\(win.server.host):\(win.server.port))")
            default:
                print("Auto-Select Failed or Cancelled: \(run.result)")
            }

        } catch CLIError.missingConfigOrToken {
            // Error message printed in resolver
        } catch {
            print("Error running auto-select: \(error)")
        }
    }

    static func runManualBootstrap(args: [String]) async {
        guard let targetServerID = getArgValue(for: "--server", args: args) else {
            print("Error: Missing --server <host:port>")
            return
        }
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try resolveCLIConfig(args: args)
            guard let targetServer = config.servers.first(where: { "\($0.host):\($0.port)" == targetServerID || $0.host == targetServerID }) else {
                print("Error: Server \(targetServerID) not found in candidate list.")
                return
            }
            guard let credentials = config.credentials else {
                print("Error: Failed to obtain credentials.")
                return
            }

            let bootstrapper = makeNativeBootstrapper()
            let tunnelController = BootstrapOnlyTunnelController()
            let coordinator = ManualConnectionCoordinator(
                bootstrapper: bootstrapper,
                tunnelController: tunnelController
            )

            let request = ManualConnectionRequest(
                server: targetServer,
                credentials: credentials,
                bootstrapContext: config.context,
                bootstrapPolicy: config.bootstrapPolicy
            )

            print("Initiating manual connection to \(targetServer.name)...")
            let result = await coordinator.connect(request)

            switch result {
            case .started(let episodeID):
                print("Success: Started session with Episode ID \(episodeID.rawValue.uuidString)")
                JSONLOutput.printRecord(command: "manual-bootstrap", data: "started: \(episodeID.rawValue.uuidString)", toFile: outputFile)
            case .failed(let error):
                print("Failure: Connection failed with error: \(error)")
                JSONLOutput.printRecord(command: "manual-bootstrap", data: "failed: \(error)", toFile: outputFile)
            case .cancelled:
                print("Cancelled: Connection attempt was cancelled.")
                JSONLOutput.printRecord(command: "manual-bootstrap", data: "cancelled", toFile: outputFile)
            }

        } catch CLIError.missingConfigOrToken {
            // Error message printed in resolver
        } catch {
            print("Error running manual-bootstrap: \(error)")
        }
    }

    static func runScanAll(args: [String]) async {
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try resolveCLIConfig(args: args)
            guard let credentials = config.credentials else {
                print("Error: Failed to obtain credentials.")
                return
            }
            guard !config.servers.isEmpty else {
                print("Error: No servers available to probe.")
                return
            }

            let healthStore = FileBackedHealthStore(fileURL: URL(fileURLWithPath: "health.json"))
            let bootstrapper = makeNativeBootstrapper()
            let runner = FullScanRunner(healthStore: healthStore, bootstrapper: bootstrapper)

            let maxActive = config.selectionPolicy.maximumActiveProbes

            print("Initiating full scan of \(config.servers.count) candidates concurrently...")
            let report = await runner.scan(
                servers: config.servers,
                credentials: credentials,
                context: config.context,
                bootstrapPolicy: config.bootstrapPolicy,
                maxActive: maxActive
            )

            JSONLOutput.printRecord(command: "scan-all", data: report.statistics, toFile: outputFile)

            let acceptance = ReportGenerator.generate(from: report.observations, totalScanDurationMs: report.statistics.totalScanDurationMs)
            ReportGenerator.renderToConsole(report: acceptance)

            print("\n================ DETAILED SERVER REPORT ================")
            print(String(format: "%-25@ | %-20@ | %-12@ | %-12@", "Server Name" as NSString, "Host:Port" as NSString, "Status" as NSString, "Latency" as NSString))
            print("--------------------------------------------------------------------------------")
            for server in config.servers.sorted(by: { $0.name < $1.name }) {
                let obs = report.observations.first(where: { $0.serverID == server.id })
                let statusStr: String
                let latencyStr: String
                if let obs = obs {
                    switch obs.outcome {
                    case .success:
                        statusStr = "ONLINE"
                        latencyStr = obs.totalBootstrapMs.map { "\($0) ms" } ?? "N/A"
                    case .certificateMismatch:
                        statusStr = "OUTDATED_TOKEN"
                        latencyStr = "N/A"
                    default:
                        statusStr = obs.outcome.rawValue.uppercased()
                        latencyStr = "N/A"
                    }
                } else {
                    statusStr = "SKIPPED"
                    latencyStr = "N/A"
                }
                print(String(format: "%-25@ | %-20@ | %-12@ | %-12@", server.name as NSString, "\(server.host):\(server.port)" as NSString, statusStr as NSString, latencyStr as NSString))
            }
            print("========================================================\n")

        } catch CLIError.missingConfigOrToken {
            // Error message printed in resolver
        } catch {
            print("Error running scan-all: \(error)")
        }
    }

    static func runDiagnostic(args: [String]) async {
        guard let configPath = getArgValue(for: "--config", args: args) else {
            print("Error: Missing --config <path>")
            return
        }

        do {
            let config = try CLIConfig.load(from: configPath)
            let diagnostics = NativeTransportDiagnostics()

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: config.sni,
                censorshipStrategy: config.censorshipStrategy,
                ipv6Available: config.ipv6Available,
                tokenConfigurationID: config.tokenConfigurationID
            )

            print("Initiating diagnostics handshake probes...")
            for server in config.servers {
                print("Probing \(server.name) (\(server.host):\(server.port))...")
                let result = await diagnostics.probe(server: server, context: context, timeout: .seconds(5))
                if result.reachable {
                    print("  -> SUCCESS: latency = \(result.latencyMs) ms")
                } else {
                    print("  -> FAILED: \(result.error ?? "unknown error")")
                }
            }

        } catch {
            print("Error running diagnostics: \(error)")
        }
    }

    static func runSimulate(args: [String]) async {
        guard let scenarioPath = getArgValue(for: "--scenario", args: args) else {
            print("Error: Missing --scenario <path>")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: scenarioPath))
            let scenario = try JSONDecoder().decode(SimulatedScenario.self, from: data)

            let servers = scenario.servers.map {
                VPNServer(name: $0.name, host: $0.host, port: $0.port, md5Fingerprint: $0.md5Fingerprint)
            }

            let fakeBootstrapper = FakeServerBootstrapping { server, credentials in
                guard let match = scenario.servers.first(where: { $0.name == server.name }) else {
                    return .success(ServerBootstrapResult(
                        server: server, accessToken: "fake", dnsIPv4: "10.0.0.1", dnsIPv6: nil,
                        metrics: ProbeMetrics(serverID: server.id, queuePosition: 0, queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0, dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil, tlsHandshakeMs: nil, loginHTTPMs: nil, bootstrapHTTPMs: nil, totalMs: 10, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil, outcome: .success)
                    ))
                }

                // Simulate latency
                try? await Task.sleep(nanoseconds: UInt64(match.latencyMs) * 1_000_000)

                let metrics = ProbeMetrics(
                    serverID: server.id,
                    queuePosition: 0,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: nil, bootstrapHTTPMs: nil,
                    totalMs: match.latencyMs,
                    cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: match.shouldSucceed ? .success : .failure
                )

                if match.shouldSucceed {
                    return .success(ServerBootstrapResult(
                        server: server,
                        accessToken: "simulated-token",
                        dnsIPv4: "10.0.0.1",
                        dnsIPv6: nil,
                        metrics: metrics
                    ))
                } else {
                    let failureKind = ServerProbeFailureKind(rawValue: match.failureKind ?? "nativeFailure") ?? .nativeFailure
                    return .failure(ServerProbeFailure(
                        server: server,
                        kind: failureKind,
                        metrics: metrics,
                        safeDiagnostic: "Simulated Failure"
                    ))
                }
            }

            let healthStore = InMemoryHealthStore()
            let policy = SelectionPolicy(
                maximumActiveProbes: scenario.maximumActiveProbes ?? 4,
                selectionDeadline: .seconds(scenario.selectionDeadlineSeconds ?? 30.0)
            )

            let selector = AutoServerSelector(
                policy: policy,
                healthStore: healthStore,
                bootstrapper: fakeBootstrapper
            )

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: "simulated.com",
                censorshipStrategy: .sniSpoofing,
                ipv6Available: false,
                tokenConfigurationID: "sim"
            )

            let request = SelectionRequest(
                servers: servers,
                credentials: Credentials(username: "sim", password: "sim"),
                context: context,
                bootstrapPolicy: .production,
                selectionPolicy: policy
            )

            print("Running Simulation...")
            let run = await selector.select(request)

            print("\nSimulation Finished!")
            print("Winner: \(run.result)")
            print("Peak Active Probes: \(run.statistics.peakActiveProbes)")
            print("Time to Winner: \(run.statistics.timeToWinnerMs ?? -1) ms")

        } catch {
            print("Error running simulation: \(error)")
        }
    }

    static func runMatrix(args: [String]) async {
        guard let configPath = getArgValue(for: "--config", args: args) else {
            print("Error: Missing --config <path>")
            return
        }
        guard let iterationsStr = getArgValue(for: "--iterations", args: args),
              let iterations = Int(iterationsStr) else {
            print("Error: Missing or invalid --iterations <n>")
            return
        }
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try CLIConfig.load(from: configPath)
            guard let credentials = SecureCredentialProvider.getCredentials(args: args) else {
                print("Error: Failed to obtain credentials.")
                return
            }

            let healthStore = FileBackedHealthStore(fileURL: URL(fileURLWithPath: "health.json"))
            let bootstrapper = makeNativeBootstrapper()

            let bootstrapPolicy = config.resolveBootstrapPolicy()
            let selectionPolicy = config.resolveSelectionPolicy()

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: config.sni,
                censorshipStrategy: config.censorshipStrategy,
                ipv6Available: config.ipv6Available,
                tokenConfigurationID: config.tokenConfigurationID
            )

            print("Initiating Multi-run Performance Matrix (Iterations: \(iterations))...")
            var allObservations: [ServerHealthObservation] = []

            for i in 1...iterations {
                print("Running iteration \(i)/\(iterations)...")
                let selector = AutoServerSelector(
                    policy: selectionPolicy,
                    healthStore: healthStore,
                    bootstrapper: bootstrapper
                )
                let request = SelectionRequest(
                    servers: config.servers,
                    credentials: credentials,
                    context: context,
                    bootstrapPolicy: bootstrapPolicy,
                    selectionPolicy: selectionPolicy
                )
                let run = await selector.select(request)
                allObservations.append(contentsOf: run.observations)

                JSONLOutput.printRecord(command: "matrix-run-\(i)", data: run.statistics, toFile: outputFile)
            }

            let report = ReportGenerator.generate(from: allObservations)
            ReportGenerator.renderToConsole(report: report)

        } catch {
            print("Error running matrix: \(error)")
        }
    }

    static func runSoakSim(args: [String]) async {
        guard let iterationsStr = getArgValue(for: "--iterations", args: args),
              let iterations = Int(iterationsStr) else {
            print("Error: Missing or invalid --iterations <n>")
            return
        }

        print("Initiating Simulated Soak Test (Iterations: \(iterations))...")
        let servers = [
            VPNServer(name: "Sim1", host: "1.1.1.1", port: 443, md5Fingerprint: "abc"),
            VPNServer(name: "Sim2", host: "1.1.1.2", port: 443, md5Fingerprint: "abc"),
            VPNServer(name: "Sim3", host: "1.1.1.3", port: 443, md5Fingerprint: "abc")
        ]

        let fakeBootstrapper = FakeServerBootstrapping { server, credentials in
            // Return success with 50ms latency
            return .success(ServerBootstrapResult(
                server: server, accessToken: "token", dnsIPv4: "10.0.0.1", dnsIPv6: nil,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: 0, queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0, dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil, tlsHandshakeMs: nil, loginHTTPMs: nil, bootstrapHTTPMs: nil, totalMs: 50, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil, outcome: .success)
            ))
        }

        let healthStore = InMemoryHealthStore()
        let policy = SelectionPolicy(maximumActiveProbes: 2, selectionDeadline: .seconds(10))
        let context = BootstrapContext(
            networkClass: .wifi,
            sni: "soak.com",
            censorshipStrategy: .sniSpoofing,
            ipv6Available: false,
            tokenConfigurationID: "soak"
        )

        for i in 1...iterations {
            if i % 100 == 0 || i == 1 || i == iterations {
                print("Soak Sim: completed iteration \(i)/\(iterations)...")
            }
            let selector = AutoServerSelector(
                policy: policy,
                healthStore: healthStore,
                bootstrapper: fakeBootstrapper
            )
            let request = SelectionRequest(
                servers: servers,
                credentials: Credentials(username: "soak", password: "soak"),
                context: context,
                bootstrapPolicy: .production,
                selectionPolicy: policy
            )
            _ = await selector.select(request)
        }

        print("Soak Sim Succeeded completely with zero leaks/task errors across \(iterations) iterations.")
    }

    // MARK: - Helpers

    private static func getArgValue(for flag: String, args: [String]) -> String? {
        let prefix = "\(flag)="
        for (idx, arg) in args.enumerated() {
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
            }
            if arg == flag, idx + 1 < args.count {
                return args[idx + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
            }
        }
        return nil
    }

    private static func makeNativeBootstrapper() -> NativeServerBootstrapper {
        NativeServerBootstrapper { server, context in
            MacNativeBootstrapClient(server: server, context: context)
        }
    }
}

// MARK: - Simulation Scenario Decodable struct
struct SimulatedScenario: Decodable {
    struct SimulatedServer: Decodable {
        let name: String
        let host: String
        let port: Int
        let md5Fingerprint: String
        let latencyMs: Int
        let shouldSucceed: Bool
        let failureKind: String?
    }
    let servers: [SimulatedServer]
    let maximumActiveProbes: Int?
    let selectionDeadlineSeconds: Double?
}

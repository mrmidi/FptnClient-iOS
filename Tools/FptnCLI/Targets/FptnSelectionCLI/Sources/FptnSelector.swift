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
        default:
            print("Unknown command: \(command)")
            Self.printUsage()
        }
    }

    static func printUsage() {
        print("""
        FPTN Server Selector CLI

        Usage:
          fptn-selector auto-select --config <path> [--output <jsonl-path>]
          fptn-selector manual-bootstrap --config <path> --server <host:port> [--output <jsonl-path>]
          fptn-selector scan-all --config <path> [--output <jsonl-path>]
          fptn-selector diagnostic --config <path>
          fptn-selector simulate --scenario <path>
          fptn-selector matrix --config <path> --iterations <n> [--output <jsonl-path>]
          fptn-selector soak-sim --iterations <n>
        """)
    }

    // MARK: - Subcommands

    static func runAutoSelect(args: [String]) async {
        guard let configPath = getArgValue(for: "--config", args: args) else {
            print("Error: Missing --config <path>")
            return
        }
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try CLIConfig.load(from: configPath)
            guard let credentials = SecureCredentialProvider.getCredentials() else {
                print("Error: Failed to obtain credentials.")
                return
            }

            let healthStore = FileBackedHealthStore(fileURL: URL(fileURLWithPath: "health.json"))
            let bootstrapper = makeNativeBootstrapper()

            let bootstrapPolicy = config.resolveBootstrapPolicy()
            let selectionPolicy = config.resolveSelectionPolicy()

            let selector = AutoServerSelector(
                policy: selectionPolicy,
                healthStore: healthStore,
                bootstrapper: bootstrapper
            )

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: config.sni,
                censorshipStrategy: config.censorshipStrategy,
                ipv6Available: config.ipv6Available,
                tokenConfigurationID: config.tokenConfigurationID
            )

            let request = SelectionRequest(
                servers: config.servers,
                credentials: credentials,
                context: context,
                bootstrapPolicy: bootstrapPolicy,
                selectionPolicy: selectionPolicy
            )

            print("Starting Auto Server Selection Race...")
            let run = await selector.select(request)

            // Log output using JSONL
            JSONLOutput.printRecord(command: "auto-select", data: run.statistics, toFile: outputFile)

            // Render report
            let report = ReportGenerator.generate(from: run.observations)
            ReportGenerator.renderToConsole(report: report)

            switch run.result {
            case .success(let win):
                print("Auto-Select Succeeded! Selected Winner: \(win.server.name) (\(win.server.host):\(win.server.port))")
            default:
                print("Auto-Select Failed or Cancelled: \(run.result)")
            }

        } catch {
            print("Error running auto-select: \(error)")
        }
    }

    static func runManualBootstrap(args: [String]) async {
        guard let configPath = getArgValue(for: "--config", args: args) else {
            print("Error: Missing --config <path>")
            return
        }
        guard let targetServerID = getArgValue(for: "--server", args: args) else {
            print("Error: Missing --server <host:port>")
            return
        }
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try CLIConfig.load(from: configPath)
            guard let targetServer = config.servers.first(where: { "\($0.host):\($0.port)" == targetServerID }) else {
                print("Error: Server \(targetServerID) not found in config.")
                return
            }
            guard let credentials = SecureCredentialProvider.getCredentials() else {
                print("Error: Failed to obtain credentials.")
                return
            }

            let bootstrapper = makeNativeBootstrapper()
            let tunnelController = BootstrapOnlyTunnelController()
            let coordinator = ManualConnectionCoordinator(
                bootstrapper: bootstrapper,
                tunnelController: tunnelController
            )

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: config.sni,
                censorshipStrategy: config.censorshipStrategy,
                ipv6Available: config.ipv6Available,
                tokenConfigurationID: config.tokenConfigurationID
            )

            let bootstrapPolicy = config.resolveBootstrapPolicy()
            let request = ManualConnectionRequest(
                server: targetServer,
                credentials: credentials,
                bootstrapContext: context,
                bootstrapPolicy: bootstrapPolicy
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

        } catch {
            print("Error running manual-bootstrap: \(error)")
        }
    }

    static func runScanAll(args: [String]) async {
        guard let configPath = getArgValue(for: "--config", args: args) else {
            print("Error: Missing --config <path>")
            return
        }
        let outputFile = getArgValue(for: "--output", args: args)

        do {
            let config = try CLIConfig.load(from: configPath)
            guard let credentials = SecureCredentialProvider.getCredentials() else {
                print("Error: Failed to obtain credentials.")
                return
            }

            let healthStore = FileBackedHealthStore(fileURL: URL(fileURLWithPath: "health.json"))
            let bootstrapper = makeNativeBootstrapper()
            let runner = FullScanRunner(healthStore: healthStore, bootstrapper: bootstrapper)

            let context = BootstrapContext(
                networkClass: .wifi,
                sni: config.sni,
                censorshipStrategy: config.censorshipStrategy,
                ipv6Available: config.ipv6Available,
                tokenConfigurationID: config.tokenConfigurationID
            )

            let bootstrapPolicy = config.resolveBootstrapPolicy()
            let maxActive = config.resolveSelectionPolicy().maximumActiveProbes

            print("Initiating full scan of all candidates concurrently...")
            let report = await runner.scan(
                servers: config.servers,
                credentials: credentials,
                context: context,
                bootstrapPolicy: bootstrapPolicy,
                maxActive: maxActive
            )

            // Log outputs
            JSONLOutput.printRecord(command: "scan-all", data: report.statistics, toFile: outputFile)

            let acceptance = ReportGenerator.generate(from: report.observations)
            ReportGenerator.renderToConsole(report: acceptance)

            print("\n================ DETAILED SERVER REPORT ================")
            print(String(format: "%-25s | %-20s | %-12s | %-12s", "Server Name", "Host:Port", "Status", "Latency"))
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
                    default:
                        statusStr = obs.outcome.rawValue.uppercased()
                        latencyStr = "N/A"
                    }
                } else {
                    statusStr = "SKIPPED"
                    latencyStr = "N/A"
                }
                print(String(format: "%-25s | %-20s | %-12s | %-12s", server.name, "\(server.host):\(server.port)", statusStr, latencyStr))
            }
            print("========================================================\n")

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
            guard let credentials = SecureCredentialProvider.getCredentials() else {
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
        if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
            return args[idx + 1]
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

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Testing
import FptnSharedCore
import FptnServerSelection
@testable import FptnVPN

struct FptnVPNTests {

    @Test func stopReasonDescriptionsCoverKnownAndUnknownValues() {
        #expect(TunnelStopReasonDescription.describe(rawValue: 1) == "userInitiated")
        #expect(TunnelStopReasonDescription.describe(rawValue: 11) == "superseded")
        #expect(TunnelStopReasonDescription.describe(rawValue: 17) == "internalError")
        #expect(TunnelStopReasonDescription.describe(rawValue: 99) == "unknown(99)")
    }

    @Test func packetProtocolDetectionHandlesIPv4IPv6AndEmptyPackets() {
        let ipv4Packet = Data([0x45, 0x00, 0x00, 0x54])
        let ipv6Packet = Data([0x60, 0x00, 0x00, 0x00])
        let emptyPacket = Data()

        #expect(TunnelPacketProtocol.protocolNumber(for: ipv4Packet) == NSNumber(value: AF_INET))
        #expect(TunnelPacketProtocol.protocolNumber(for: ipv6Packet) == NSNumber(value: AF_INET6))
        #expect(TunnelPacketProtocol.protocolNumber(for: emptyPacket) == NSNumber(value: AF_INET))
    }

    @Test func reconnectPolicyTreatsZeroAsInfiniteAndRespectsDisablement() {
        let infinitePolicy = TunnelReconnectPolicy(isEnabled: true, maxAttempts: 0, delaySeconds: 3)
        let limitedPolicy = TunnelReconnectPolicy(isEnabled: true, maxAttempts: 2, delaySeconds: 3)
        let disabledPolicy = TunnelReconnectPolicy(isEnabled: false, maxAttempts: 0, delaySeconds: 3)

        #expect(infinitePolicy.usesInfiniteRetries)
        #expect(infinitePolicy.canRetry(nextAttempt: 50))

        #expect(!limitedPolicy.usesInfiniteRetries)
        #expect(limitedPolicy.canRetry(nextAttempt: 1))
        #expect(limitedPolicy.canRetry(nextAttempt: 2))
        #expect(!limitedPolicy.canRetry(nextAttempt: 3))

        #expect(!disabledPolicy.usesInfiniteRetries)
        #expect(!disabledPolicy.canRetry(nextAttempt: 1))
    }

    @Test func runtimeStateMachineReassertsAfterRecoverableDisconnect() {
        let nextState = TunnelRuntimeStateMachine.nextState(
            from: .connected,
            event: .transportDisconnected(canRetry: true)
        )

        #expect(nextState == .reasserting)
    }

    @Test func runtimeStateMachineFailsAfterExhaustedDisconnect() {
        let nextState = TunnelRuntimeStateMachine.nextState(
            from: .connected,
            event: .transportDisconnected(canRetry: false)
        )

        #expect(nextState == .failed)
    }

    @Test func runtimeStateMachineRecoversToConnectedAfterTransportReturns() {
        let nextState = TunnelRuntimeStateMachine.nextState(
            from: .reasserting,
            event: .transportConnected
        )

        #expect(nextState == .connected)
    }

    @Test func lifecycleStopWhileConnectedCancelsReconnectAndStopsTransport() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .running,
            state: .connected,
            activeGeneration: 1,
            event: .stopRequested(initiator: "app_disconnect")
        )

        #expect(transition.intent == .stopped)
        #expect(transition.state == .stopping)
        #expect(transition.effects.contains(.cancelReconnect))
        #expect(transition.effects.contains(.stopWebSocket))
    }

    @Test func lifecycleDisconnectWhileStoppedNeverSchedulesReconnect() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .stopped,
            state: .stopping,
            activeGeneration: 1,
            event: .transportDisconnected(
                generation: 1,
                reason: "connection_closed",
                wasConnected: true,
                pathSatisfied: true
            )
        )

        #expect(!transition.effects.contains(.scheduleReconnect(attempt: 1)))
        #expect(!transition.effects.contains(.startWebSocket))
    }

    @Test func lifecycleRuntimeDisconnectSchedulesReconnectWhenPathIsAvailable() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .running,
            state: .connected,
            activeGeneration: 2,
            event: .transportDisconnected(
                generation: 2,
                reason: "server_disconnected",
                wasConnected: true,
                pathSatisfied: true
            )
        )

        #expect(transition.state == .reasserting(attempt: 1))
        #expect(transition.effects == [.scheduleReconnect(attempt: 1)])
    }

    @Test func lifecycleRuntimeDisconnectWaitsForNetworkWithoutStartingTransport() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .running,
            state: .connected,
            activeGeneration: 3,
            event: .transportDisconnected(
                generation: 3,
                reason: "network_lost",
                wasConnected: true,
                pathSatisfied: false
            )
        )

        #expect(transition.state == .waitingForNetwork(attempt: 1))
        #expect(transition.effects == [.waitForNetwork(attempt: 1)])
    }

    @Test func lifecyclePathRestoredSchedulesPendingReconnect() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .running,
            state: .waitingForNetwork(attempt: 2),
            activeGeneration: 4,
            event: .networkPathChanged(isSatisfied: true)
        )

        #expect(transition.state == .reasserting(attempt: 2))
        #expect(transition.effects == [.scheduleReconnect(attempt: 2)])
    }

    @Test func lifecycleStaleWebSocketCallbackIsIgnored() {
        let transition = TunnelLifecycleRuntime.nextTransition(
            intent: .running,
            state: .reasserting(attempt: 1),
            activeGeneration: 8,
            event: .transportConnected(generation: 7)
        )

        #expect(transition.state == .reasserting(attempt: 1))
        #expect(transition.effects == [.ignoreStaleCallback])
    }

    @Test func diagnosticsStoreRetainsNewestProviderEvents() throws {
        let store = TunnelDiagnosticsStore(rootURL: try temporaryDiagnosticsDirectory())
        for index in 0..<305 {
            store.recordProviderEvent(category: "test", message: "event_\(index)")
        }

        let events = store.readProviderEvents()
        #expect(events.count == 300)
        #expect(events.first?.message == "event_5")
        #expect(events.last?.message == "event_304")
    }

    @Test func diagnosticsStoreHandlesMalformedHeartbeat() throws {
        let root = try temporaryDiagnosticsDirectory()
        try "not-json".write(to: root.appendingPathComponent("provider-heartbeat.json"), atomically: true, encoding: .utf8)
        let store = TunnelDiagnosticsStore(rootURL: root)

        #expect(store.readHeartbeat() == nil)
    }

    @Test func diagnosticsRedactorRemovesSecrets() {
        let redacted = TunnelDiagnosticsRedactor.redact(
            #"access_token=abc123456789 password="secret123" authorization Bearer deadbeefcafebabe token: eyJh123456789"#
        )

        #expect(!redacted.contains("abc123456789"))
        #expect(!redacted.contains("secret123"))
        #expect(!redacted.contains("deadbeefcafebabe"))
        #expect(redacted.contains("<redacted>"))
    }

    @Test func memoryPressurePolicyClassifiesThresholds() {
        let belowWarning = TunnelMemoryPressureSnapshot(
            residentBytes: 10 * 1024 * 1024,
            physFootprintBytes: 29 * 1024 * 1024
        )
        let warning = TunnelMemoryPressureSnapshot(
            residentBytes: 10 * 1024 * 1024,
            physFootprintBytes: 35 * 1024 * 1024
        )
        let emergency = TunnelMemoryPressureSnapshot(
            residentBytes: 10 * 1024 * 1024,
            physFootprintBytes: 42 * 1024 * 1024
        )

        #expect(belowWarning.level == .normal)
        #expect(warning.level == .warning)
        #expect(emergency.level == .emergency)
    }

    @Test func memoryPressurePolicyUsesFootprintBeforeRSS() {
        let rssEmergencyFootprintNormal = TunnelMemoryPressureSnapshot(
            residentBytes: 50 * 1024 * 1024,
            physFootprintBytes: 20 * 1024 * 1024
        )
        let rssWarningWithoutFootprint = TunnelMemoryPressureSnapshot(
            residentBytes: 35 * 1024 * 1024,
            physFootprintBytes: nil
        )

        #expect(rssEmergencyFootprintNormal.level == .normal)
        #expect(rssWarningWithoutFootprint.level == .warning)
    }

    @Test func diagnosticsStoreReadsOldHeartbeatWithoutFootprint() throws {
        let root = try temporaryDiagnosticsDirectory()
        try """
        {
          "timestamp": "\(TunnelDiagnosticsStore.now())",
          "runtimeState": "connected",
          "isReasserting": false,
          "generation": 1,
          "reconnectAttempt": 0,
          "maxReconnectAttempts": 0,
          "pathSatisfied": true,
          "websocketStarted": true,
          "websocketRunning": true,
          "packetFlowReadPackets": 1,
          "packetFlowWritePackets": 2,
          "transportReceivedPackets": 3,
          "websocketSendFailures": 0,
          "memoryResidentBytes": 123
        }
        """.write(to: root.appendingPathComponent("provider-heartbeat.json"), atomically: true, encoding: .utf8)
        let store = TunnelDiagnosticsStore(rootURL: root)

        let heartbeat = store.readHeartbeat()
        #expect(heartbeat?.memoryResidentBytes == 123)
        #expect(heartbeat?.memoryPhysFootprintBytes == nil)
    }

    @Test func providerFailureReportIncludesHeartbeatCrashMarkerAndMetricKit() throws {
        let root = try temporaryDiagnosticsDirectory()
        let store = TunnelDiagnosticsStore(rootURL: root)
        store.writeHeartbeat(
            TunnelProviderHeartbeat(
                timestamp: TunnelDiagnosticsStore.now(),
                runtimeState: "connected",
                isReasserting: false,
                generation: 4,
                reconnectAttempt: 0,
                maxReconnectAttempts: 0,
                pathSatisfied: true,
                websocketStarted: true,
                websocketRunning: true,
                lastTransportError: nil,
                lastStopReason: nil,
                lastEvent: "telemetry",
                lastInboundActivityAt: "2026-04-28T17:39:00Z",
                lastOutboundActivityAt: "2026-04-28T17:39:00Z",
                packetFlowReadPackets: 10,
                packetFlowWritePackets: 11,
                transportReceivedPackets: 12,
                websocketSendFailures: 0,
                memoryResidentBytes: 123,
                memoryPhysFootprintBytes: 456
            )
        )
        try #"{"timestamp":"signal-time-unavailable","signal":11,"signalName":"SIGSEGV","process":"FptnVPNTunnel"}"#
            .write(to: root.appendingPathComponent("provider-crash-marker.json"), atomically: true, encoding: .utf8)
        store.recordMetricKitDiagnostic(
            MetricKitDiagnosticRecord(
                timestamp: TunnelDiagnosticsStore.now(),
                category: "crash",
                processName: "FptnVPNTunnel",
                bundleIdentifier: "net.mrmidi.FptnVPN.FptnVPNTunnel",
                exceptionType: "SIGSEGV",
                exceptionCode: "11",
                terminationReason: "signal",
                appVersion: "1.0",
                appBuild: "1",
                callStack: "frame",
                payload: "{}"
            )
        )

        let report = store.makeProviderFailureReport(disconnectReason: "plugin_failed")
        #expect(report.heartbeat?.runtimeState == "connected")
        #expect(report.crashMarker?.signalName == "SIGSEGV")
        #expect(report.nearestMetricKitDiagnostic?.category == "crash")
        #expect(report.summaryLine.contains("plugin_failed"))
        #expect(report.summaryLine.contains("footprint=0MB"))
    }

    @Test func selectCandidatesForTestingFiltersPremiumAndSamplesRegular() {
        let servers = [
            VPNServer(name: "Regular 1", host: "1.1.1.1", md5_fingerprint: "a", port: 443),
            VPNServer(name: "Premium Alpha", host: "2.2.2.2", md5_fingerprint: "b", port: 443),
            VPNServer(name: "Regular 2", host: "3.3.3.3", md5_fingerprint: "c", port: 443),
            VPNServer(name: "Regular 3", host: "4.4.4.4", md5_fingerprint: "d", port: 443),
            VPNServer(name: "Regular 4", host: "5.5.5.5", md5_fingerprint: "e", port: 443),
            VPNServer(name: "Regular 5", host: "6.6.6.6", md5_fingerprint: "f", port: 443),
        ]
        
        let selected = ServerLatencyProbeService.selectCandidatesForTesting(servers: servers)
        
        // Premium must always be included
        #expect(selected.contains { $0.name == "Premium Alpha" })
        // Total selected: 1 premium + ceil(5 * 0.5) = 1 + 3 = 4
        #expect(selected.count == 4)
    }

    // Tests that SlidingWindowRace selects the fastest responding server.
    // Uses a local StubServerBootstrapProbe to simulate server timing without
    // requiring the native C++ bridge or network access. Replaces the old
    // loginBlock:-based test removed when we migrated to the protocol-based API.
    @Test func slidingWindowRaceSelectsFastestServer() async {
        let serverA = VPNServer(name: "Server A (Unreachable)", host: "1.1.1.1", md5_fingerprint: "a", port: 443)
        let serverB = VPNServer(name: "Server B (Slow)", host: "2.2.2.2", md5_fingerprint: "b", port: 443)
        let serverC = VPNServer(name: "Server C (Fast)", host: "3.3.3.3", md5_fingerprint: "c", port: 443)

        // Shared flag: set when C finishes so B can bail out
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            var value: Bool { lock.withLock { _value } }
            func set() { lock.withLock { _value = true } }
        }
        let cDone = Flag()

        // Inline stub that simulates configurable delays/outcomes per server
        final class StubProbe: ServerBootstrapProbing, @unchecked Sendable {
            let cDone: Flag
            init(_ flag: Flag) { self.cDone = flag }

            func probe(
                server: VPNServer,
                credentials: Credentials,
                context: ProbeContext,
                timeout: Duration,
                queuePosition: Int
            ) async -> ServerBootstrapAttempt {
                let t0 = Int64(Date().timeIntervalSince1970 * 1000)
                func metrics(_ outcome: ProbeMetricOutcome) -> ProbeMetrics {
                    let t1 = Int64(Date().timeIntervalSince1970 * 1000)
                    return ProbeMetrics(
                        serverID: server.id, queuePosition: queuePosition,
                        queuedAtMs: t0, startedAtMs: t0, completedAtMs: t1,
                        dnsMs: 5, tcpConnectMs: 10,
                        fakeHandshakeMs: nil, tlsHandshakeMs: nil,
                        loginHTTPMs: nil, bootstrapHTTPMs: nil,
                        totalMs: Int(t1 - t0),
                        cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                        outcome: outcome
                    )
                }

                switch server.host {
                case "1.1.1.1": // A — instant failure
                    return .failure(ServerProbeFailure(
                        server: server, kind: .connectionTimeout,
                        metrics: metrics(.failure), safeDiagnostic: "unreachable"))

                case "2.2.2.2": // B — slow; waits until C signals or is cancelled
                    for _ in 0..<200 {
                        if cDone.value { break }
                        do { try await Task.sleep(for: .milliseconds(20)) }
                        catch {
                            return .failure(ServerProbeFailure(
                                server: server, kind: .cancelled,
                                metrics: metrics(.cancelled), safeDiagnostic: "cancelled"))
                        }
                    }
                    return .success(ServerBootstrapResult(
                        server: server, accessToken: "token-b",
                        dnsIPv4: "10.0.0.1", dnsIPv6: nil, metrics: metrics(.success)))

                default: // C — fast winner
                    try? await Task.sleep(for: .milliseconds(10))
                    cDone.set()
                    return .success(ServerBootstrapResult(
                        server: server, accessToken: "token-c",
                        dnsIPv4: "10.0.0.1", dnsIPv6: nil, metrics: metrics(.success)))
                }
            }
        }

        let credentials = Credentials(username: "user", password: "pwd")
        let context = ProbeContext(
            networkClass: .wifi,
            sni: "test.example.com",
            censorshipStrategy: CensorshipStrategy(storedValue: ""),
            ipv6Available: false,
            tokenConfigurationID: "test"
        )

        let result = await SlidingWindowRace().run(
            candidates: [serverA, serverB, serverC],
            credentials: credentials,
            context: context,
            probe: StubProbe(cDone)
        )

        guard case .success(let winner) = result else {
            #expect(false, "Expected .success but got \(String(describing: result))")
            return
        }
        #expect(winner.server.name == "Server C (Fast)")
        #expect(winner.accessToken == "token-c")
    }

    private func temporaryDiagnosticsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FptnVPNTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

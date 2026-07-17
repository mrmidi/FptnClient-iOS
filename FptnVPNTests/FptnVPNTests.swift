/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Testing
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

    @Test func raceServerHandshakesSelectsFastestServer() async {
        let serverA = VPNServer(name: "Premium A (Unreachable)", host: "1.1.1.1", md5_fingerprint: "a", port: 443)
        let serverB = VPNServer(name: "Premium B (Slow)", host: "2.2.2.2", md5_fingerprint: "b", port: 443)
        let serverC = VPNServer(name: "Premium C (Fast)", host: "3.3.3.3", md5_fingerprint: "c", port: 443)
        
        class RaceCoordinator: @unchecked Sendable {
            private let lock = NSLock()
            private var _cFinished = false
            
            var cFinished: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _cFinished
            }
            
            func markCFinished() {
                lock.lock()
                _cFinished = true
                lock.unlock()
            }
        }
        
        let coordinator = RaceCoordinator()
        let service = ServerLatencyProbeService()
        let result = await service.raceServerHandshakes(
            servers: [serverA, serverB, serverC],
            probeBlock: { server in
                if server.name == "Premium A (Unreachable)" {
                    return nil
                } else if server.name == "Premium B (Slow)" {
                    // Loop and sleep until C is finished or we are cancelled
                    for _ in 0..<200 {
                        if coordinator.cFinished {
                            // If C has finished, we return nil so B never races C's return
                            return nil
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(50))
                        } catch {
                            return nil
                        }
                    }
                    return ServerLatencyProbeResult(
                        server: server,
                        state: .reachable,
                        latencyMs: 1000,
                        detail: "verified_http_200",
                        checkedAt: Date().timeIntervalSince1970
                    )
                } else if server.name == "Premium C (Fast)" {
                    try? await Task.sleep(for: .milliseconds(10))
                    coordinator.markCFinished()
                    return ServerLatencyProbeResult(
                        server: server,
                        state: .reachable,
                        latencyMs: 50,
                        detail: "verified_http_200",
                        checkedAt: Date().timeIntervalSince1970
                    )
                }
                return nil
            }
        )
        
        #expect(result?.server.name == "Premium C (Fast)")
        #expect(result?.latencyMs == 50)
    }

    private func temporaryDiagnosticsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FptnVPNTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

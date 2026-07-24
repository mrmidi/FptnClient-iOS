/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Testing
import FptnSharedCore
import FptnSharedTunnel
import FptnServerSelection
import FptnConnectionOrchestration
import FptnNativeBootstrap
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

    // PR-1 (Measurement Safety): the emergency threshold (42 MiB) must not
    // stop, replace, or reconnect the native WebSocket bridge. The provider's
    // response at both warning and emergency is log-only — no bridge
    // destruction, generation bump, reconnect scheduling, or state transition.
    @Test func memoryPressureActionIsLogOnlyAtAllThresholds() {
        #expect(TunnelMemoryPressureAction.action(for: .normal) == .none)
        #expect(TunnelMemoryPressureAction.action(for: .warning) == .logOnly)
        #expect(TunnelMemoryPressureAction.action(for: .emergency) == .logOnly)

        let emergency = TunnelMemoryPressureSnapshot(
            residentBytes: 50 * 1024 * 1024,
            physFootprintBytes: 45 * 1024 * 1024
        )
        #expect(emergency.level == .emergency)
        #expect(TunnelMemoryPressureAction.action(for: emergency.level) == .logOnly)

        let exactlyAtEmergency = TunnelMemoryPressureSnapshot(
            residentBytes: nil,
            physFootprintBytes: TunnelMemoryPressureSnapshot.emergencyThresholdBytes
        )
        #expect(exactlyAtEmergency.level == .emergency)

        let oneBelowEmergency = TunnelMemoryPressureSnapshot(
            residentBytes: nil,
            physFootprintBytes: TunnelMemoryPressureSnapshot.emergencyThresholdBytes - 1
        )
        #expect(oneBelowEmergency.level == .warning)
        #expect(TunnelMemoryPressureAction.action(for: oneBelowEmergency.level) == .logOnly)
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
                memoryPhysFootprintBytes: 456,
                localStopInitiator: nil,
                nativeDisconnectCode: nil,
                nativeStopOrigin: nil
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

    // PR1B: WebsocketSendResult enum mapping from C++ bridge uint8_t.
    @Test func sendResultMapsBridgeValues() {
        #expect(WebsocketSendResult(bridgeValue: 0) == .accepted)
        #expect(WebsocketSendResult(bridgeValue: 1) == .queueFull)
        #expect(WebsocketSendResult(bridgeValue: 2) == .transportStopped)
        #expect(WebsocketSendResult(bridgeValue: 3) == .invalidPacket)
        #expect(WebsocketSendResult(bridgeValue: 99) == .unknown)
        #expect(WebsocketSendResult(bridgeValue: 255) == .unknown)
    }

    // PR1B: only .queueFull should feed backpressure. .transportStopped
    // breaks the batch. .invalidPacket is counted but does not slow
    // valid traffic. This test documents the policy; the C++ level
    // accounting tests (byte reservation CAS, rollback, gauge
    // lifecycle, batch bounds) require fptn gtest infrastructure.
    @Test func sendResultBackpressurePolicy() {
        let queueFull: WebsocketSendResult = .queueFull
        let stopped: WebsocketSendResult = .transportStopped
        let invalid: WebsocketSendResult = .invalidPacket

        var sendFailures: Int64 = 0
        var invalidPackets: Int64 = 0
        var transportStopped = false

        for result in [queueFull, queueFull, stopped, invalid] {
            switch result {
            case .accepted: break
            case .queueFull: sendFailures += 1
            case .transportStopped:
                transportStopped = true
            case .invalidPacket, .unknown:
                invalidPackets += 1
            }
        }

        #expect(sendFailures == 2)
        #expect(transportStopped == true)
        #expect(invalidPackets == 1)
    }

    // PR2: disconnect code and stop origin enum mapping.
    @Test func disconnectCodeAndStopOriginMapBridgeValues() {
        #expect(WebsocketDisconnectCode(bridgeValue: 0) == .none)
        #expect(WebsocketDisconnectCode(bridgeValue: 1) == .peerClosed)
        #expect(WebsocketDisconnectCode(bridgeValue: 5) == .watchdog)
        #expect(WebsocketDisconnectCode(bridgeValue: 6) == .localStop)
        #expect(WebsocketDisconnectCode(bridgeValue: 99) == .unknown)

        #expect(WebsocketStopOrigin(bridgeValue: 0) == .none)
        #expect(WebsocketStopOrigin(bridgeValue: 1) == .swiftTunnelStop)
        #expect(WebsocketStopOrigin(bridgeValue: 2) == .swiftReconnect)
        #expect(WebsocketStopOrigin(bridgeValue: 3) == .nativeFailure)
        #expect(WebsocketStopOrigin(bridgeValue: 4) == .peer)
        #expect(WebsocketStopOrigin(bridgeValue: 200) == .unknown)
    }

    // PR2: heartbeat with typed stop fields decodes correctly.
    @Test func heartbeatDecodesTypedStopFields() throws {
        let root = try temporaryDiagnosticsDirectory()
        let store = TunnelDiagnosticsStore(rootURL: root)
        store.writeHeartbeat(
            TunnelProviderHeartbeat(
                timestamp: TunnelDiagnosticsStore.now(),
                runtimeState: "connected",
                isReasserting: false,
                generation: 1,
                reconnectAttempt: 0,
                maxReconnectAttempts: 5,
                pathSatisfied: true,
                websocketStarted: true,
                websocketRunning: true,
                lastTransportError: nil,
                lastStopReason: nil,
                lastEvent: "telemetry",
                lastInboundActivityAt: nil,
                lastOutboundActivityAt: nil,
                packetFlowReadPackets: 0,
                packetFlowWritePackets: 0,
                transportReceivedPackets: 0,
                websocketSendFailures: 0,
                memoryResidentBytes: nil,
                memoryPhysFootprintBytes: nil,
                localStopInitiator: "app_disconnect",
                nativeDisconnectCode: 6,
                nativeStopOrigin: 1
            )
        )
        let heartbeat = store.readHeartbeat()
        #expect(heartbeat?.localStopInitiator == "app_disconnect")
        #expect(heartbeat?.nativeDisconnectCode == 6)
        #expect(heartbeat?.nativeStopOrigin == 1)
    }

    // PR2: old heartbeat without typed fields still decodes (backward compat).
    @Test func heartbeatDecodesWithoutTypedStopFields() throws {
        let root = try temporaryDiagnosticsDirectory()
        try #"{"timestamp":"2026-01-01T00:00:00Z","runtimeState":"connected","isReasserting":false,"generation":1,"reconnectAttempt":0,"maxReconnectAttempts":5,"pathSatisfied":true,"websocketStarted":true,"websocketRunning":true,"lastTransportError":null,"lastStopReason":null,"lastEvent":"telemetry","lastInboundActivityAt":null,"lastOutboundActivityAt":null,"packetFlowReadPackets":0,"packetFlowWritePackets":0,"transportReceivedPackets":0,"websocketSendFailures":0,"memoryResidentBytes":null,"memoryPhysFootprintBytes":null}"#
            .write(to: root.appendingPathComponent("provider-heartbeat.json"), atomically: true, encoding: .utf8)
        let store = TunnelDiagnosticsStore(rootURL: root)
        let heartbeat = store.readHeartbeat()
        #expect(heartbeat != nil)
        #expect(heartbeat?.localStopInitiator == nil)
        #expect(heartbeat?.nativeDisconnectCode == nil)
        #expect(heartbeat?.nativeStopOrigin == nil)
    }

    @Test func tunnelStartupConfigurationV1EncodesAndValidatesSuccessfully() throws {
        let episodeID = UUID()
        let config = try TunnelStartupConfigurationV1(
            episodeID: episodeID,
            recoveryPolicy: .none,
            serverHost: "1.1.1.1",
            serverPort: 443,
            accessToken: "tok_test",
            dnsIPv4: "1.1.1.1",
            sni: "sni.test",
            md5Fingerprint: "fp_test",
            censorshipStrategy: CensorshipStrategy(storedValue: "sni")
        )

        let encoded = try JSONEncoder().encode(config)
        #expect(encoded.count <= TunnelStartupConfigurationV1.maximumEncodedSize)

        let decoded = try JSONDecoder().decode(TunnelStartupConfigurationV1.self, from: encoded)
        #expect(decoded.episodeID == episodeID)
        #expect(decoded.serverHost == "1.1.1.1")
        #expect(decoded.accessToken == "tok_test")
    }

    // Schema v2 lifecycle snapshot: exact session traffic totals, peak
    // bandwidth, and queue/lease health round-trip through the C ABI.
    @Test func lifecycleSnapshotV2RoundTripsTrafficAndHealthFields() throws {
        let root = try temporaryDiagnosticsDirectory()
        let snapshotPath = root.appendingPathComponent("lifecycle-snapshot.bin").path
        let store = try #require(TunnelLifecycleSnapshotStore(path: snapshotPath))

        let wrote = store.write(
            pid: 123,
            processToken: 1,
            processSequence: 1,
            processStartedMachTime: 1,
            tunnelSessionToken: 42,
            tunnelStartedMachTime: 1,
            sessionAcceptedUploadBytes: 111_222,
            sessionAcceptedDownloadBytes: 333_444,
            peakUploadBytesPerSecond: 5_000,
            peakDownloadBytesPerSecond: 60_000,
            queueFullCount: 3,
            livePacketLeases: 4,
            peakPacketLeases: 9,
            peakBandwidthNominalWindowSeconds: 15,
            synchronize: true
        )
        #expect(wrote)

        let decoder = TunnelDiagnosticsDecoder(
            ringPath: root.appendingPathComponent("flight-ring.bin").path,
            snapshotPath: snapshotPath
        )
        let snapshot = try #require(decoder.readLifecycleSnapshot())

        #expect(snapshot.sessionAcceptedUploadBytes == 111_222)
        #expect(snapshot.sessionAcceptedDownloadBytes == 333_444)
        #expect(snapshot.peakUploadBytesPerSecond == 5_000)
        #expect(snapshot.peakDownloadBytesPerSecond == 60_000)
        #expect(snapshot.queueFullCount == 3)
        #expect(snapshot.livePacketLeases == 4)
        #expect(snapshot.peakPacketLeases == 9)
        #expect(snapshot.peakBandwidthNominalWindowSeconds == 15)
    }

    // No dual-decode path: a record whose schema_version doesn't match
    // kSchemaVersion (2) must be rejected outright, not decoded as v1.
    @Test func lifecycleSnapshotRejectsWrongSchemaVersion() throws {
        let root = try temporaryDiagnosticsDirectory()
        let snapshotPath = root.appendingPathComponent("lifecycle-snapshot.bin").path
        let store = try #require(TunnelLifecycleSnapshotStore(path: snapshotPath))
        #expect(store.write(
            pid: 1, processToken: 1, processSequence: 1, processStartedMachTime: 1,
            tunnelSessionToken: 1, tunnelStartedMachTime: 1, synchronize: true
        ))

        // schema_version is a little-endian u16 at byte offset 4 of whichever
        // 512-byte slot the store picked for this write (LifecycleStore
        // alternates slots and a fresh file may start at either one).
        // Corrupt it at both possible slot offsets so the test doesn't
        // depend on that internal choice — the untouched slot is still
        // all-zero and already fails the magic check on its own.
        var data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        #expect(data.count >= 1024)
        data[4] = 0xFF
        data[5] = 0xFF
        data[516] = 0xFF
        data[517] = 0xFF
        try data.write(to: URL(fileURLWithPath: snapshotPath))

        let decoder = TunnelDiagnosticsDecoder(
            ringPath: root.appendingPathComponent("flight-ring.bin").path,
            snapshotPath: snapshotPath
        )
        #expect(decoder.readLifecycleSnapshot() == nil)
    }

    // A record too short to contain the v2 layout (240 bytes) must be
    // rejected, not partially decoded with garbage trailing fields.
    @Test func lifecycleSnapshotRejectsTruncatedRecord() throws {
        let root = try temporaryDiagnosticsDirectory()
        let snapshotPath = root.appendingPathComponent("lifecycle-snapshot.bin").path
        let store = try #require(TunnelLifecycleSnapshotStore(path: snapshotPath))
        #expect(store.write(
            pid: 1, processToken: 1, processSequence: 1, processStartedMachTime: 1,
            tunnelSessionToken: 1, tunnelStartedMachTime: 1, synchronize: true
        ))

        let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        try data.prefix(64).write(to: URL(fileURLWithPath: snapshotPath))

        let decoder = TunnelDiagnosticsDecoder(
            ringPath: root.appendingPathComponent("flight-ring.bin").path,
            snapshotPath: snapshotPath
        )
        #expect(decoder.readLifecycleSnapshot() == nil)
    }

    private func temporaryDiagnosticsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FptnVPNTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

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
}

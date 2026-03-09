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
}

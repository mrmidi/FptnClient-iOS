/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

enum TunnelProviderRuntimeState: String, Codable, Sendable {
    case idle
    case starting
    case connected
    case reasserting
    case waitingForNetwork
    case stopping
    case failed
}

struct TunnelRuntimeSnapshot: Codable, Sendable {
    let runtimeState: TunnelProviderRuntimeState
    let isReasserting: Bool
    let reconnectAttempt: Int
    let maxReconnectAttempts: Int
    let lastTransportError: String?
    let lastStopReason: String?
    let lastStopReasonRawValue: Int?
    let localStopInitiator: String?
    let lastInboundActivityAt: String?
    let lastOutboundActivityAt: String?
    let packetFlowReadPackets: Int64
    let packetFlowReadBytes: Int64
    let transportReceivedPackets: Int64
    let transportReceivedBytes: Int64
    let packetFlowWritePackets: Int64
    let packetFlowWriteBytes: Int64
    let websocketSendFailures: Int64
    let dnsIPv4: String?
    let dnsIPv6: String?
    let tunnelIPv4: String?
    let tunnelIPv6: String?
    let ipv6Enabled: Bool
    let websocketRunning: Bool
    let websocketStarted: Bool
    let websocketIdleTimeoutSeconds: Int
    let websocketLastError: String?
    let websocketLastDisconnectReason: String?
}

struct TunnelReconnectPolicy: Equatable, Sendable {
    let isEnabled: Bool
    let maxAttempts: Int
    let delaySeconds: Int

    var usesInfiniteRetries: Bool {
        isEnabled && maxAttempts == 0
    }

    func canRetry(nextAttempt: Int) -> Bool {
        guard isEnabled else { return false }
        return maxAttempts == 0 || nextAttempt <= maxAttempts
    }
}

enum TunnelPacketProtocol {
    static func protocolNumber(for packet: Data) -> NSNumber {
        guard let first = packet.first else {
            return NSNumber(value: AF_INET)
        }
        return NSNumber(value: Int32(Int(first >> 4) == 6 ? AF_INET6 : AF_INET))
    }
}

enum TunnelRuntimeTransitionEvent {
    case transportConnected
    case transportDisconnected(canRetry: Bool)
    case stopRequested
    case startFailed
}

struct TunnelRuntimeStateMachine {
    static func nextState(
        from state: TunnelProviderRuntimeState,
        event: TunnelRuntimeTransitionEvent
    ) -> TunnelProviderRuntimeState {
        switch (state, event) {
        case (_, .stopRequested):
            return .stopping
        case (.idle, .transportConnected):
            return .connected
        case (.starting, .transportConnected):
            return .connected
        case (.reasserting, .transportConnected):
            return .connected
        case (.starting, .startFailed):
            return .failed
        case (.connected, .transportDisconnected(let canRetry)):
            return canRetry ? .reasserting : .failed
        case (.reasserting, .transportDisconnected(let canRetry)):
            return canRetry ? .reasserting : .failed
        case (.starting, .transportDisconnected):
            return .failed
        case (.failed, _):
            return .failed
        case (.stopping, _):
            return .stopping
        default:
            return state
        }
    }
}

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

enum TunnelStopReasonDescription {
    static func describe(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "none"
        case 1: return "userInitiated"
        case 2: return "providerFailed"
        case 3: return "noNetworkAvailable"
        case 4: return "unrecoverableNetworkChange"
        case 5: return "providerDisabled"
        case 6: return "authenticationCanceled"
        case 7: return "configurationFailed"
        case 8: return "idleTimeout"
        case 9: return "configurationDisabled"
        case 10: return "configurationRemoved"
        case 11: return "superseded"
        case 12: return "userLogout"
        case 13: return "userSwitch"
        case 14: return "connectionFailed"
        case 15: return "sleep"
        case 16: return "appUpdate"
        case 17: return "internalError"
        default: return "unknown(\(rawValue))"
        }
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

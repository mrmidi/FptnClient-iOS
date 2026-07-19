/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore

public enum ManualConnectionState: Sendable, Equatable {
    case idle
    case bootstrapping
    case startingTunnel
    case connected(ConnectionEpisodeID)
    case disconnecting
    case disconnected(ManualDisconnectReason)
    case failed(ManualConnectionFailure)
}

public enum ManualDisconnectReason: Sendable, Equatable {
    case userInitiated
    case remoteClosed
    case networkLost
    case appBackgroundedTooLong
}

public struct ManualConnectionFailure: Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

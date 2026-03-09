/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

enum ServerLatencyState: String, Codable, Sendable {
    case reachable
    case timeout
    case unreachable

    var isReachable: Bool {
        self == .reachable
    }

    var sortRank: Int {
        switch self {
        case .reachable: return 0
        case .timeout: return 1
        case .unreachable: return 2
        }
    }
}

struct ServerLatencyRecord: Codable, Sendable, Hashable, Identifiable {
    let serverID: String
    let state: ServerLatencyState
    let latencyMs: Int?
    let detail: String
    let checkedAt: TimeInterval

    var id: String { serverID }

    var isReachable: Bool {
        state.isReachable
    }
}

struct ServerLatencyProbeResult: Sendable, Hashable, Identifiable {
    let server: VPNServer
    let state: ServerLatencyState
    let latencyMs: Int?
    let detail: String
    let checkedAt: TimeInterval

    var id: String { server.id }

    var cacheRecord: ServerLatencyRecord {
        ServerLatencyRecord(
            serverID: server.id,
            state: state,
            latencyMs: latencyMs,
            detail: detail,
            checkedAt: checkedAt
        )
    }
}

struct ServerLatencyProgress: Sendable {
    let done: Int
    let total: Int
    let reachable: Int
    let timeout: Int
    let unreachable: Int
    let best: ServerLatencyProbeResult?
}

enum ServerLatencyEvent: Sendable {
    case result(ServerLatencyProbeResult)
    case progress(ServerLatencyProgress)
    case finished
}

struct ServerListRow: Sendable, Hashable, Identifiable {
    let server: VPNServer
    let latency: ServerLatencyRecord?

    var id: String { server.id }

    var isReachable: Bool {
        latency?.isReachable == true
    }

    var latencyText: String {
        guard let latency else { return "--" }
        switch latency.state {
        case .reachable:
            if let latencyMs = latency.latencyMs {
                return "\(latencyMs) ms"
            }
            return "--"
        case .timeout:
            return "timeout"
        case .unreachable:
            return "unreachable"
        }
    }

    static func sorted(_ rows: [ServerListRow]) -> [ServerListRow] {
        rows.sorted { lhs, rhs in
            let lhsState = lhs.latency?.state.sortRank ?? Int.max
            let rhsState = rhs.latency?.state.sortRank ?? Int.max
            if lhsState != rhsState {
                return lhsState < rhsState
            }

            let lhsLatency = lhs.latency?.latencyMs ?? Int.max
            let rhsLatency = rhs.latency?.latencyMs ?? Int.max
            if lhsLatency != rhsLatency {
                return lhsLatency < rhsLatency
            }

            return lhs.server.name.localizedCaseInsensitiveCompare(rhs.server.name) == .orderedAscending
        }
    }
}

struct AutoServerSelection: Sendable {
    let selectedServer: VPNServer?
    let rows: [ServerListRow]
}
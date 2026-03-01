/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

enum ProbeStatus: String, Codable, Sendable {
    case reachable   = "REACHABLE"
    case unreachable = "UNREACHABLE"
}

struct ProbeResult: Codable, Identifiable, Sendable {
    var id: String { sni }
    let sni: String
    let status: ProbeStatus
    let latencyMs: Int    // actual RTT; -1 means timeout/error
    let detail: String    // "HTTP 200", "HTTP 401", or error string
    let ts: Double
}

struct ProbeConfig: Sendable {
    var server: VPNServer
    var bypassMethod: BypassMethod = .sniSpoofing
    var timeoutMs: Int = 5000
    var concurrency: Int = 5
}

struct ScanProgress: Sendable {
    let done, total, reachable, unreachable: Int
    var best: ProbeResult?
}

enum ScanEvent: Sendable {
    case result(ProbeResult)
    case progress(ScanProgress)
    case finished
}

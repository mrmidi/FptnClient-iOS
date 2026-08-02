/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class ServerLatencyCache {
    static let shared = ServerLatencyCache()

    private(set) var latencies: [String: ServerLatencyRecord] = [:]

    init() {}

    func update(record: ServerLatencyRecord) {
        latencies[record.serverID] = record
    }

    func update(records: [String: ServerLatencyRecord]) {
        latencies.merge(records) { _, new in new }
    }

    func getLatency(for serverID: String) -> ServerLatencyRecord? {
        latencies[serverID]
    }

    func clear() {
        latencies.removeAll()
    }
}

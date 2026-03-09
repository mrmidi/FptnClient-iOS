/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

actor ServerLatencyCacheService {
    static let shared = ServerLatencyCacheService()

    private static let storageKey = "fptn.serverLatency.cache"
    private static let ttl: TimeInterval = 15 * 60

    func freshRecords() -> [String: ServerLatencyRecord] {
        let now = Date().timeIntervalSince1970
        return loadAll().filter { _, record in
            now - record.checkedAt <= Self.ttl
        }
    }

    func save(_ record: ServerLatencyRecord) {
        var records = loadAll()
        records[record.serverID] = record
        persist(records)
    }

    func save(_ results: [ServerLatencyProbeResult]) {
        var records = loadAll()
        for result in results {
            records[result.server.id] = result.cacheRecord
        }
        persist(records)
    }

    private func loadAll() -> [String: ServerLatencyRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: ServerLatencyRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ records: [String: ServerLatencyRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
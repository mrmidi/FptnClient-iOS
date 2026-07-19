/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

public actor FileBackedHealthStore: ServerHealthStore {
    private let fileURL: URL
    private var records: [ServerHealthKey: ServerHealthRecord] = [:]
    private var isLoaded: Bool = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            isLoaded = true
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let recordsList = try decoder.decode([ServerHealthRecord].self, from: data)
            for record in recordsList {
                records[record.key] = record
            }
            isLoaded = true
        } catch {
            print("Warning: Failed to load server health records (or file corrupted). Starting fresh. Error: \(error)")
            // Backup corrupt file
            let backupURL = fileURL.appendingPathExtension("corrupt")
            try? fm.removeItem(at: backupURL)
            try? fm.moveItem(at: fileURL, to: backupURL)
            records = [:]
            isLoaded = true
        }
    }

    private func save() throws {
        let parentDir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let recordsList = Array(records.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(recordsList)
        
        // Atomic write
        try data.write(to: fileURL, options: [.atomic])
    }

    public func load(for keys: [ServerHealthKey]) async throws -> [ServerHealthKey: ServerHealthRecord] {
        ensureLoaded()
        var result: [ServerHealthKey: ServerHealthRecord] = [:]
        for key in keys {
            if let record = records[key] {
                result[key] = record
            }
        }
        return result
    }

    public func apply(_ updates: [ServerHealthUpdate]) async throws {
        ensureLoaded()
        let policy = ServerHealthPolicy()
        for update in updates {
            let existing = records[update.key] ?? ServerHealthRecord(key: update.key)
            records[update.key] = policy.apply(observation: update.observation, to: existing)
        }
        try save()
    }
}

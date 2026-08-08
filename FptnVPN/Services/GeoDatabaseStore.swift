/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import CryptoKit
import Foundation
import os

// MARK: - Source

/// Where the geo data comes from.
///
/// The lists are compiled and published by the roscomvpn project, not by FPTN.
/// That is stated in the UI as well: someone deciding whether to trust these
/// routing rules needs to know whose opinion they encode.
enum GeoDatabaseSource {
    static let attribution = "roscomvpn"
    static let projectURL = URL(string: "https://github.com/hydraponique")!

    static func downloadURL(for kind: GeoDataKind) -> URL {
        switch kind {
        case .geoip:
            URL(string: "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat")!
        case .geosite:
            URL(string: "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat")!
        }
    }
}

// MARK: - Errors

enum GeoDatabaseStoreError: Error, LocalizedError {
    case noSharedContainer
    case httpStatus(Int, kind: GeoDataKind)
    case emptyResponse(GeoDataKind)

    var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            "The shared app group container is unavailable."
        case .httpStatus(let code, let kind):
            "Downloading \(kind.fileName) failed with HTTP \(code)."
        case .emptyResponse(let kind):
            "\(kind.fileName) came back empty."
        }
    }
}

// MARK: - Store

/// Downloads, stores and decodes the geo database.
///
/// Files land in the shared app group container rather than the app's own
/// documents directory. Nothing outside the app reads them yet — split routing
/// still runs its built-in test policy — but putting them anywhere else would
/// mean moving them later, and the container is the only location both
/// processes can name.
@MainActor
final class GeoDatabaseStore: ObservableObject {

    enum State {
        /// Nothing downloaded yet, or the files were removed.
        case absent
        case downloading
        case parsing
        case ready(GeoDatabase)
        case failed(String)

        var database: GeoDatabase? {
            if case .ready(let database) = self { return database }
            return nil
        }

        var isBusy: Bool {
            switch self {
            case .downloading, .parsing: true
            case .absent, .ready, .failed: false
            }
        }
    }

    @Published private(set) var state: State = .absent

    private let logger = Logger(subsystem: "org.fptn", category: "geodb")
    private let appGroup = "group.net.mrmidi.FptnVPN"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Locations

    private var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("GeoDatabase", isDirectory: true)
    }

    private func fileURL(for kind: GeoDataKind) -> URL? {
        directory?.appendingPathComponent(kind.fileName)
    }

    private var manifestURL: URL? {
        directory?.appendingPathComponent("manifest.json")
    }

    /// True when both files and their provenance are on disk. Checked before
    /// showing the empty state, so a returning user is not asked to download
    /// something they already have.
    var hasStoredFiles: Bool {
        guard let manifestURL, FileManager.default.fileExists(atPath: manifestURL.path) else {
            return false
        }
        return GeoDataKind.allCases.allSatisfy { kind in
            guard let url = fileURL(for: kind) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: Actions

    /// Loads whatever is already on disk. Does not hit the network.
    func loadStored() async {
        guard hasStoredFiles else {
            state = .absent
            return
        }
        state = .parsing
        do {
            let manifest = try readManifest()
            let database = try await Self.parse(
                ipURL: try require(fileURL(for: .geoip)),
                siteURL: try require(fileURL(for: .geosite)),
                ipProvenance: try require(manifest[GeoDataKind.geoip.rawValue]),
                siteProvenance: try require(manifest[GeoDataKind.geosite.rawValue])
            )
            state = .ready(database)
            logger.info("Loaded geo database: \(database.totalRuleCount) rules")
        } catch {
            logger.error("Loading the stored geo database failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads both files, replaces what is stored, then parses.
    ///
    /// Both files are fetched before either is written. A half-applied update
    /// would pair a new IP table with an old domain table, and the manifest
    /// would describe neither.
    func download() async {
        state = .downloading
        do {
            let ip = try await fetch(.geoip)
            let site = try await fetch(.geosite)

            let directory = try require(directory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try ip.data.write(to: try require(fileURL(for: .geoip)), options: .atomic)
            try site.data.write(to: try require(fileURL(for: .geosite)), options: .atomic)
            try writeManifest([
                GeoDataKind.geoip.rawValue: ip.provenance,
                GeoDataKind.geosite.rawValue: site.provenance,
            ])

            state = .parsing
            let database = try await Self.parse(
                ipData: ip.data,
                siteData: site.data,
                ipProvenance: ip.provenance,
                siteProvenance: site.provenance
            )
            state = .ready(database)
            logger.info("Downloaded geo database: \(database.totalRuleCount) rules")
        } catch {
            logger.error("Downloading the geo database failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Removes the stored files. Used to get back to a clean first-run state.
    func removeStored() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        state = .absent
    }

    // MARK: Networking

    private func fetch(_ kind: GeoDataKind) async throws -> (data: Data, provenance: GeoFileProvenance) {
        let url = GeoDatabaseSource.downloadURL(for: kind)
        // Ignore the local URL cache. The CDN decides its own freshness; a
        // cached body here would make "Update" quietly do nothing.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GeoDatabaseStoreError.httpStatus(http.statusCode, kind: kind)
        }
        guard !data.isEmpty else { throw GeoDatabaseStoreError.emptyResponse(kind) }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, GeoFileProvenance(
            sourceURL: url,
            fetchedAt: Date(),
            byteCount: data.count,
            sha256: digest
        ))
    }

    // MARK: Manifest

    private func readManifest() throws -> [String: GeoFileProvenance] {
        let data = try Data(contentsOf: try require(manifestURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: GeoFileProvenance].self, from: data)
    }

    private func writeManifest(_ manifest: [String: GeoFileProvenance]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: try require(manifestURL), options: .atomic)
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw GeoDatabaseStoreError.noSharedContainer }
        return value
    }

    // MARK: Parsing

    /// `nonisolated` so decoding runs off the main actor. It is only a few
    /// milliseconds for the current files, but it scales with whatever the
    /// publisher ships next, and blocking the UI for it would be gratuitous.
    private nonisolated static func parse(
        ipData: Data,
        siteData: Data,
        ipProvenance: GeoFileProvenance,
        siteProvenance: GeoFileProvenance
    ) async throws -> GeoDatabase {
        let started = ContinuousClock.now
        let ip = try GeoDatParser.parseGeoIP(ipData)
        let site = try GeoDatParser.parseGeoSite(siteData)
        return GeoDatabase(
            ip: ip,
            site: site,
            ipProvenance: ipProvenance,
            siteProvenance: siteProvenance,
            parseDuration: ContinuousClock.now - started
        )
    }

    private nonisolated static func parse(
        ipURL: URL,
        siteURL: URL,
        ipProvenance: GeoFileProvenance,
        siteProvenance: GeoFileProvenance
    ) async throws -> GeoDatabase {
        // Mapped rather than read: the files are read once and never mutated,
        // so the pages can be dropped under pressure instead of being copied
        // onto the heap.
        let ipData = try Data(contentsOf: ipURL, options: .mappedIfSafe)
        let siteData = try Data(contentsOf: siteURL, options: .mappedIfSafe)
        return try await parse(
            ipData: ipData,
            siteData: siteData,
            ipProvenance: ipProvenance,
            siteProvenance: siteProvenance
        )
    }
}

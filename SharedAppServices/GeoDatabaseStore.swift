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
    static let russiaListURL = URL(string: "https://raw.githubusercontent.com/fptn-project/fptn/master/deploy/domain_blacklist/russia.txt")!

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

enum GeoDatabaseStoreError: Error, LocalizedError, Sendable {
    case noSharedContainer
    case httpStatus(Int, kind: GeoDataKind)
    case emptyResponse(GeoDataKind)
    case compilationFailed(String)
    case stagingIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            "The shared app group container is unavailable."
        case .httpStatus(let code, let kind):
            "Downloading \(kind.fileName) failed with HTTP \(code)."
        case .emptyResponse(let kind):
            "\(kind.fileName) came back empty."
        case .compilationFailed(let message):
            "Compiling the geo routing artifact failed: \(message)"
        case .stagingIncomplete(let name):
            "\(name) was missing after compilation."
        }
    }
}

// MARK: - Provisioning

/// Result of an automatic (not user-initiated) provisioning attempt.
///
/// The distinction that matters is `failedButUsable` vs `unavailable`: on a
/// censored network the download is expected to fail, and a user who already
/// has a database must not be told anything is wrong — nor may the failed
/// attempt have cost them the database they had.
enum GeoProvisionOutcome: Equatable, Sendable {
    /// Present and fresh enough; nothing was fetched.
    case upToDate
    /// Downloaded and compiled successfully.
    case refreshed
    /// The update failed but a usable database is still published.
    case failedButUsable(String)
    /// No usable database. Split routing still runs — every flow simply falls
    /// to the default verdict, which is the server.
    case unavailable(reason: GeoProvisionFailureReason, message: String)

    var isUsable: Bool {
        switch self {
        case .upToDate, .refreshed, .failedButUsable: true
        case .unavailable: false
        }
    }
}

/// Why provisioning produced nothing usable. The two cases need different
/// advice: a blocked download is worth retrying over the tunnel, whereas lists
/// that cannot be turned into a policy will fail identically however they are
/// fetched.
enum GeoProvisionFailureReason: Equatable, Sendable {
    /// The lists could not be fetched — typically a network blocking the CDN.
    case download
    /// The lists arrived but no routing policy could be built from them.
    case policy
}

// MARK: - Store

/// Downloads, stores and decodes the geo database.
///
/// Files land in the shared app group container rather than the app's own
/// documents directory. The app compiles the raw pair into `geo-routing.bin`
/// in that same directory before it publishes the manifest. The packet-tunnel
/// extension maps that immutable artifact; it does not parse or compile source
/// lists on its packet-routing path. The manifest is a publish marker: it is
/// removed before the swap and written last, so the extension either sees a
/// complete artifact or safely stays tunnel-only.
///
/// Updates download and compile into a staging directory and are moved into
/// place only once known good. That ordering is the point: on a censored
/// network the CDN is unreachable and lists may be refused, and a user who
/// cannot re-download must not lose the database they already have to a failed
/// attempt at replacing it.
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

    /// Shared instance. Provisioning is triggered from app launch and from the
    /// data-plane picker as well as from the Geo Database screen, and all three
    /// have to observe the same state — otherwise a background refresh would be
    /// invisible to a screen holding its own copy.
    static let shared = GeoDatabaseStore()

    /// The publisher cuts a release roughly once a day (`Release 202608090434`,
    /// `Release 202608080419`, …), so anything older than this is worth
    /// refetching and anything younger is not.
    nonisolated static let refreshInterval: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "org.fptn", category: "geodb")
    private let compiledArtifactFileName = "geo-routing.bin"
    private let stagingDirectoryName = "staging"
    private let session: URLSession

    /// The job in flight, if any. See `performExclusively(_:)`.
    private var jobTask: Task<GeoDatabase, Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Locations

    private var directory: URL? {
        FptnAppGroup.containerURL?
            .appendingPathComponent("GeoDatabase", isDirectory: true)
    }

    private func fileURL(for kind: GeoDataKind) -> URL? {
        directory?.appendingPathComponent(kind.fileName)
    }

    private var manifestURL: URL? {
        directory?.appendingPathComponent("manifest.json")
    }

    private var compiledArtifactURL: URL? {
        directory?.appendingPathComponent(compiledArtifactFileName)
    }

    /// Scratch space for an update in progress. Everything is downloaded and
    /// compiled in here and only moved into place once it is known good, so a
    /// failed update cannot damage the database already being routed on.
    private var stagingURL: URL? {
        directory?.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    private var hasCompiledArtifact: Bool {
        guard let compiledArtifactURL else { return false }
        return FileManager.default.fileExists(atPath: compiledArtifactURL.path)
    }

    /// Size and mtime of the published artifact, for the log. Whether the
    /// tunnel is routing on a fresh artifact or a months-old one is the first
    /// thing worth knowing, and file existence alone does not say.
    private var compiledArtifactDescription: String {
        guard let compiledArtifactURL,
              let attributes = try? FileManager.default
                  .attributesOfItem(atPath: compiledArtifactURL.path)
        else { return "absent" }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)
            .map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return "\(size) bytes, built \(modified)"
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

    /// True when the tunnel would actually find something to route on. The
    /// manifest is the commit marker and the artifact is what gets mapped, so
    /// both have to be there — source lists alone are not a routing database.
    var isPublished: Bool { hasStoredFiles && hasCompiledArtifact }

    /// When the stored lists were fetched, read straight from the manifest so
    /// freshness can be judged without decoding half a megabyte of protobuf.
    /// The older of the two files wins: the pair is only as fresh as its
    /// staler half.
    var storedFetchDate: Date? {
        guard let manifest = try? readManifest() else { return nil }
        return manifest.values.map(\.fetchedAt).min()
    }

    /// Whether the stored database has fallen behind the publisher's daily
    /// cadence.
    var isStale: Bool { Self.isStale(fetchedAt: storedFetchDate) }

    /// Absent counts as stale — there is nothing to keep. A date in the future
    /// (clock skew, or a file restored from a backup taken on another device)
    /// counts as fresh rather than triggering a refetch on every launch.
    nonisolated static func isStale(fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= refreshInterval
    }

    /// Whether the published artifact encodes a different opinion than the app
    /// would compile now — an older built-in mapping, or routing preferences
    /// that have since changed.
    ///
    /// Separate from `isStale`, which is about the source lists, and answered
    /// without touching the network on purpose. A device on a whitelist ISP is
    /// both the most likely to be holding an outdated policy and the least able
    /// to download a replacement, so "wait for the next refresh" would leave
    /// exactly the wrong people behind.
    var isPolicyOutdated: Bool {
        guard let directory, hasCompiledArtifact else { return false }
        let published = FPTNTunnelBridge.geoRoutingVerdictMapId(atPath: directory.path)
        // Unreadable counts as outdated: rebuilding from the stored lists is
        // both the diagnosis and the repair.
        guard published != 0 else { return true }
        return published != FPTNTunnelBridge.geoRoutingVerdictMapId(
            forRoutePushThroughTunnel: Self.routePushThroughTunnel
        )
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
            let database: GeoDatabase
            if hasCompiledArtifact {
                logger.info("Compiled artifact already present (\(self.compiledArtifactDescription)); skipping recompilation")
                database = try await parseStored(manifest: try readManifest())
            } else {
                logger.info("No compiled artifact; recompiling from the stored lists")
                database = try await performExclusively { try await self.runRecompile() }
                logger.info("Compiled the routing artifact (\(self.compiledArtifactDescription))")
            }
            state = .ready(database)
            logger.info("Loaded and compiled geo database: \(database.totalRuleCount) rules")
        } catch {
            logger.error("Loading the stored geo database failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Rebuilds the published artifact from the lists already on disk.
    ///
    /// Routing preferences are compiled into the artifact rather than consulted
    /// at run time, so changing one has no effect on the tunnel until this runs.
    /// No download is involved, which matters: the network that made the
    /// preference necessary is often the one that cannot reach the CDN.
    @discardableResult
    func recompilePolicy() async -> GeoProvisionOutcome {
        guard hasStoredFiles else {
            // Nothing to rebuild. Whenever a database does arrive it will be
            // compiled against whatever the preferences say at that point.
            logger.info("No stored geo lists; nothing to recompile")
            return .upToDate
        }
        do {
            let database = try await performExclusively { try await self.runRecompile() }
            state = .ready(database)
            logger.info("Recompiled the routing policy: \(database.totalRuleCount) rules")
            return .refreshed
        } catch {
            let message = error.localizedDescription
            logger.error("Recompiling the routing policy failed: \(message)")
            // The swap only happens once a compile has succeeded, so a failure
            // here leaves the previous artifact published and routing — just
            // not with the preference that was asked for.
            if isPublished {
                return .failedButUsable(message)
            }
            state = .failed(message)
            return .unavailable(reason: Self.failureReason(for: error), message: message)
        }
    }

    /// Downloads both files, replaces what is stored, then parses.
    ///
    /// User-initiated, so a failure is reported through `state`. Automatic
    /// paths go through `provision(force:)` instead, which keeps a working
    /// database visible rather than flipping the screen to an error.
    func download() async {
        state = .downloading
        do {
            let database = try await performExclusively { try await self.runUpdate() }
            state = .ready(database)
            logger.info("Downloaded and compiled geo database: \(database.totalRuleCount) rules")
        } catch {
            logger.error("Downloading the geo database failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Makes sure a usable database exists, fetching only when there is nothing
    /// published or what is published has aged past the publisher's daily
    /// cadence.
    ///
    /// Never throws and never downgrades a working database. On a censored
    /// network — the case this exists for — the CDN is unreachable, and the
    /// right outcome is to keep routing on whatever is already on disk and say
    /// so, not to surface a failure or wipe the database trying to replace it.
    @discardableResult
    func provision(force: Bool = false) async -> GeoProvisionOutcome {
        let published = isPublished
        guard force || !published || isStale else {
            // Fresh lists, but the policy built from them can still predate a
            // change to the built-in mapping or to a routing preference. That
            // is repairable from disk, with no download to be blocked.
            if isPolicyOutdated {
                logger.info("Geo lists are current but the policy predates the current preferences; rebuilding it from disk")
                return await recompilePolicy()
            }
            logger.info("Geo database is current (fetched \(self.storedFetchDate.map(Self.describe) ?? "unknown")); no refresh needed")
            return .upToDate
        }

        let reason = published ? "stale" : "absent"
        logger.info("Refreshing the geo database (\(reason))")

        // Only claim the screen when there is nothing to show. Replacing a
        // loaded database with a spinner to refresh it in the background would
        // hide working data behind an update the person never asked for.
        if state.database == nil {
            state = .downloading
        }

        do {
            let database = try await performExclusively { try await self.runUpdate() }
            state = .ready(database)
            logger.info("Refreshed the geo database: \(database.totalRuleCount) rules")
            return .refreshed
        } catch {
            let message = error.localizedDescription
            // Expected on a network that blocks the CDN. Logged at error level
            // because it is worth seeing in a capture, but it is not fatal
            // while something usable is still published.
            logger.error("Refreshing the geo database failed: \(message)")

            if isPublished {
                logger.info("Keeping the previously published geo database (fetched \(self.storedFetchDate.map(Self.describe) ?? "unknown"))")
                // The download is what failed, not the compiler. If the kept
                // policy encodes outdated preferences it can still be rebuilt
                // from the lists already on disk — which is the whole point of
                // separating the two.
                if isPolicyOutdated {
                    logger.info("Rebuilding the kept policy to match the current preferences")
                    _ = await recompilePolicy()
                }
                if state.database == nil {
                    await loadStored()
                }
                return .failedButUsable(message)
            }
            let reason = Self.failureReason(for: error)
            logger.error("No usable geo database (\(String(describing: reason))); split routing will run with no policy and send everything to the server")
            state = .failed(message)
            return .unavailable(reason: reason, message: message)
        }
    }

    private static func describe(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Everything that happens after both files are in hand counts as a policy
    /// failure; anything earlier is a fetch failure. The native compiler is
    /// exception-firewalled and reports through `compilationFailed`, so a
    /// malformed or unreducible list arrives here rather than as a crash.
    nonisolated static func failureReason(for error: Error) -> GeoProvisionFailureReason {
        // Exhaustive over the concrete type on purpose: a new error case should
        // not silently default to "blocked download" and give advice that
        // cannot help.
        guard let storeError = error as? GeoDatabaseStoreError else {
            return .download
        }
        switch storeError {
        case .compilationFailed, .stagingIncomplete:
            return .policy
        case .noSharedContainer, .httpStatus, .emptyResponse:
            return .download
        }
    }

    /// Runs one job at a time, joining a call already in flight rather than
    /// starting a second.
    ///
    /// The launch refresh, the data-plane picker, the push-routing switch, the
    /// Geo Database screen and the Update button can all fire independently,
    /// and this type is `@MainActor` rather than single-threaded — everything
    /// suspends at `await`. Two concurrent jobs would share one staging
    /// directory, and the second would delete the first's files out from under
    /// it.
    ///
    /// Joining is safe across job kinds because every one of them compiles with
    /// the preferences in force when it runs: a recompile that joins a download
    /// gets the artifact it was going to build anyway. The reverse costs a
    /// download the freshness it wanted, and is bounded by how long a recompile
    /// takes — well under a second, with no network involved.
    private func performExclusively(
        _ body: @escaping @MainActor () async throws -> GeoDatabase
    ) async throws -> GeoDatabase {
        if let jobTask {
            logger.info("A geo job is already in flight; joining it")
            return try await jobTask.value
        }
        let task = Task { try await body() }
        jobTask = task
        defer { jobTask = nil }
        return try await task.value
    }

    /// Fetch, compile and publish. Throws on any failure, having left whatever
    /// was already published untouched.
    ///
    /// Both files are fetched before either is written. A half-applied update
    /// would pair a new IP table with an old domain table, and the manifest
    /// would describe neither.
    private func runUpdate() async throws -> GeoDatabase {
        let ip = try await fetch(.geoip)
        let site = try await fetch(.geosite)

        let staging = try prepareStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        try ip.data.write(
            to: staging.appendingPathComponent(GeoDataKind.geoip.fileName),
            options: .atomic
        )
        try site.data.write(
            to: staging.appendingPathComponent(GeoDataKind.geosite.fileName),
            options: .atomic
        )

        // Fetch fresh regional direct domain list (russia.txt) from Git, or fallback to bundled list
        var russiaData = await fetchOptional(GeoDatabaseSource.russiaListURL)
        if russiaData == nil {
            logger.info("Using bundled fallback direct domain list (\(DefaultDirectDomainList.domainsText.utf8.count) bytes)")
            russiaData = Data(DefaultDirectDomainList.domainsText.utf8)
        }
        if let russiaData {
            try? russiaData.write(
                to: staging.appendingPathComponent("russia.txt"),
                options: .atomic
            )
            logger.info("Staged regional direct domain list (\(russiaData.count) bytes)")
        }

        logger.info("Compiling the routing artifact from \(ip.data.count) + \(site.data.count) downloaded bytes")
        try await Self.compileNativeDatabase(
            at: staging.path, routePushThroughTunnel: Self.routePushThroughTunnel
        )

        try commit(from: staging, manifest: [
            GeoDataKind.geoip.rawValue: ip.provenance,
            GeoDataKind.geosite.rawValue: site.provenance,
        ])
        logger.info("Published the routing artifact (\(self.compiledArtifactDescription))")

        state = .parsing
        return try await Self.parse(
            ipData: ip.data,
            siteData: site.data,
            ipProvenance: ip.provenance,
            siteProvenance: site.provenance
        )
    }

    /// Rebuilds the artifact from the lists already on disk, via the same
    /// staging path as a download. Compiling in place would mean deleting the
    /// manifest first and rewriting it only on success — so one rejected list
    /// would demote an otherwise intact database to "absent", and the retry
    /// would fail identically.
    private func runRecompile() async throws -> GeoDatabase {
        let manifest = try readManifest()
        let staging = try prepareStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        for kind in GeoDataKind.allCases {
            try FileManager.default.copyItem(
                at: try require(fileURL(for: kind)),
                to: staging.appendingPathComponent(kind.fileName)
            )
        }

        // Copy russia.txt into staging if present so recompilation preserves it, or write bundled fallback
        if let directory {
            let existingRussia = directory.appendingPathComponent("russia.txt")
            if FileManager.default.fileExists(atPath: existingRussia.path) {
                try? FileManager.default.copyItem(
                    at: existingRussia,
                    to: staging.appendingPathComponent("russia.txt")
                )
            } else {
                try? Data(DefaultDirectDomainList.domainsText.utf8).write(
                    to: staging.appendingPathComponent("russia.txt"),
                    options: .atomic
                )
            }
        }

        try await Self.compileNativeDatabase(
            at: staging.path, routePushThroughTunnel: Self.routePushThroughTunnel
        )
        try commit(from: staging, manifest: manifest)

        state = .parsing
        return try await parseStored(manifest: manifest)
    }

    private func parseStored(manifest: [String: GeoFileProvenance]) async throws -> GeoDatabase {
        try await Self.parse(
            ipURL: try require(fileURL(for: .geoip)),
            siteURL: try require(fileURL(for: .geosite)),
            ipProvenance: try require(manifest[GeoDataKind.geoip.rawValue]),
            siteProvenance: try require(manifest[GeoDataKind.geosite.rawValue])
        )
    }

    private func prepareStagingDirectory() throws -> URL {
        let directory = try require(directory)
        let staging = directory.appendingPathComponent(stagingDirectoryName)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )
        return staging
    }

    /// Moves a validated set from staging into place.
    ///
    /// The manifest is the tunnel's commit marker, so it is removed first and
    /// written last: the extension either sees a complete set or no database at
    /// all. The window is three renames wide, and every expensive, failure-prone
    /// step — download, compile, validation — has already happened by now.
    private func commit(from staging: URL, manifest: [String: GeoFileProvenance]) throws {
        let fileManager = FileManager.default
        let directory = try require(directory)
        var names = GeoDataKind.allCases.map(\.fileName) + [compiledArtifactFileName]
        if fileManager.fileExists(atPath: staging.appendingPathComponent("russia.txt").path) {
            names.append("russia.txt")
        }

        // Verify before destroying anything: the native compiler publishes the
        // artifact itself, and a staging set missing a file must not become a
        // half-swapped live set.
        for name in names where !fileManager.fileExists(
            atPath: staging.appendingPathComponent(name).path
        ) {
            throw GeoDatabaseStoreError.stagingIncomplete(name)
        }

        try invalidatePublishedDatabase()
        for name in names {
            let source = staging.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        try writeManifest(manifest)
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

    private func fetchOptional(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty {
                return data
            }
        } catch {
            logger.info("Optional list download skipped from \(url): \(error.localizedDescription)")
        }
        return nil
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

    private func invalidatePublishedDatabase() throws {
        if let manifestURL,
           FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw GeoDatabaseStoreError.noSharedContainer }
        return value
    }

    /// Whether Apple's push couriers should be compiled to route through the
    /// server. Read at compile time rather than stored, so every artifact this
    /// type publishes matches the preference in force when it was built.
    nonisolated static var routePushThroughTunnel: Bool {
        // The two apps keep their own settings stores; this is the only
        // platform-varying value this type reads.
        #if os(macOS)
        MacSettingsStore.readRoutePushThroughTunnel()
        #else
        SettingsService.shared.routePushThroughTunnel
        #endif
    }

    /// The compiler is synchronous native code, so keep it off the main actor.
    /// The task is awaited before the manifest is restored; the tunnel can only
    /// observe the artifact once the complete download/compile transaction is
    /// committed.
    private nonisolated static func compileNativeDatabase(
        at path: String, routePushThroughTunnel: Bool
    ) async throws {
        try await Task.detached(priority: .utility) {
            do {
                try FPTNTunnelBridge.compileGeoRoutingPolicy(
                    atPath: path, routePushThroughTunnel: routePushThroughTunnel
                )
            } catch {
                // Named here rather than only at the call site: the native
                // compiler's reason (which .dat was rejected, at which byte)
                // is the whole diagnostic, and the outer handler flattens it
                // into a generic "loading failed".
                Logger(subsystem: "org.fptn", category: "geodb").error(
                    "Native geo compilation failed at \(path): \(error.localizedDescription)"
                )
                throw GeoDatabaseStoreError.compilationFailed(
                    error.localizedDescription
                )
            }
        }.value
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

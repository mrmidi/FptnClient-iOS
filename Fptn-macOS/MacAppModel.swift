import Combine
import Foundation
import FptnSharedCore
import FptnSharedTunnel

/// Everything the window, the Settings scene and the menu bar item all need to
/// agree on. Previously this lived as `@State` inside ContentView, which made a
/// menu bar item impossible — a `MenuBarExtra` is a sibling Scene and cannot
/// reach another scene's view state.
@MainActor
final class MacAppModel: ObservableObject {

    @Published private(set) var token: MacTokenPayload?
    @Published var selectedServer: MacVPNServer?
    @Published var parseError: String?

    @Published var sni: String = MacSettingsStore.readSni() {
        didSet { MacSettingsStore.saveSni(sni) }
    }

    @Published var censorshipStrategy: CensorshipStrategy = MacSettingsStore.readCensorshipStrategy() {
        didSet { MacSettingsStore.saveCensorshipStrategy(censorshipStrategy) }
    }

    @Published var routePushThroughTunnel: Bool = MacSettingsStore.readRoutePushThroughTunnel() {
        didSet { MacSettingsStore.saveRoutePushThroughTunnel(routePushThroughTunnel) }
    }

    @Published var logLevel: SharedLogLevel = MacSettingsStore.readLogLevel() {
        didSet { MacSettingsStore.saveLogLevel(logLevel) }
    }

    /// macOS previously never sent this, so every session silently ran
    /// `l3Tunnel` -- the split classifier was unreachable from the Mac, which
    /// is the stand we profile the data plane on.
    @Published var dataPlaneMode: TunnelDataPlaneMode = MacSettingsStore.readDataPlaneMode() {
        didSet { MacSettingsStore.saveDataPlaneMode(dataPlaneMode) }
    }

    var servers: [MacVPNServer] { token?.servers ?? [] }
    var hasToken: Bool { token != nil }

    // MARK: - Token lifecycle

    /// Parses a pasted token, persists it, and mirrors it to iCloud so the iOS
    /// app picks it up. Returns false and populates `parseError` on failure.
    @discardableResult
    func applyToken(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let parsed = try MacTokenParser.parse(token: trimmed)
            token = parsed
            parseError = nil
            restoreSelection(from: parsed)

            MacSettingsStore.saveToken(trimmed)
            CloudTokenSync.saveTokenPayload(parsed)
            CloudTokenSync.savePassword(parsed.password, username: parsed.username)
            return true
        } catch {
            parseError = error.localizedDescription
            return false
        }
    }

    func signOut() {
        token = nil
        selectedServer = nil
        parseError = nil
        MacSettingsStore.saveToken("")
        MacSettingsStore.saveSelectedServer(nil)
    }

    /// Local store first, iCloud second. A device that has never had iCloud
    /// enabled still has to come back with its token after a relaunch.
    func loadPersistedToken() {
        guard token == nil else { return }

        let stored = MacSettingsStore.readToken()
        if !stored.isEmpty, (try? MacTokenParser.parse(token: stored)) != nil {
            applyToken(stored)
            return
        }

        guard var cloudToken = CloudTokenSync.loadTokenPayload() else { return }
        // `found` rather than a non-empty check: a token may genuinely carry an
        // empty password.
        let keychain = CloudTokenSync.loadPassword(username: cloudToken.username)
        if keychain.found {
            cloudToken = MacTokenPayload(
                version: cloudToken.version,
                service_name: cloudToken.serviceName,
                username: cloudToken.username,
                password: keychain.password ?? "",
                servers: cloudToken.servers
            )
        }
        token = cloudToken
        restoreSelection(from: cloudToken)
    }

    // MARK: - Server selection

    func selectServer(_ server: MacVPNServer?) {
        selectedServer = server
        MacSettingsStore.saveSelectedServer(server.map(Self.identity))
    }

    private func restoreSelection(from payload: MacTokenPayload) {
        let storedID = MacSettingsStore.readSelectedServerID()
        selectedServer = payload.servers.first { Self.identity($0) == storedID }
            ?? payload.servers.first
    }

    /// `VPNServer` carries no stable server-side ID, so host:port is the
    /// identity — it is what actually distinguishes two entries in a token.
    private static func identity(_ server: MacVPNServer) -> String {
        "\(server.host):\(server.port)"
    }
}

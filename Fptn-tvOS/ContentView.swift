import SwiftUI
import FptnSharedCore

struct ContentView: View {
    @Environment(TvVPNService.self) private var vpnService

    @State private var token: TvTokenPayload?
    @State private var selectedServer: TvVPNServer?
    @State private var selectedLogLevel: SharedLogLevel = .warning
    @State private var sni: String = "rutube.ru"
    @State private var isSynced = false
    @State private var statusMessage = "Looking for iCloud credentials..."
    @State private var smartConnect = TvServerSelectionService()
    @State private var passwordRetryTask: Task<Void, Never>?
    @State private var passwordRetryCount = 0

    private let maxPasswordRetries = 10
    private let passwordRetryDelayNanos: UInt64 = 2_000_000_000

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(.tint)

                    Text("FPTN VPN")
                        .font(.largeTitle.bold())
                }

                if let token {
                    // Synced state — show server list and connection controls
                    VStack(spacing: 20) {
                        if isSynced {
                            Label("Credentials synced from iCloud", systemImage: "icloud.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Text("Service: \(token.service_name)")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        // Server picker
                        HStack(spacing: 18) {
                            Picker("Server", selection: $selectedServer) {
                                Text("Select server").tag(Optional<TvVPNServer>.none)
                                ForEach(token.servers) { server in
                                    Text("\(server.name) (\(server.host):\(server.port))")
                                        .tag(Optional(server))
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                Task { await pickBestServer() }
                            } label: {
                                Label(smartConnect.isMeasuring ? "Measuring..." : "Smart Connect",
                                      systemImage: "bolt.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(token.servers.isEmpty || smartConnect.isMeasuring)
                        }

                        if !smartConnect.lastSelectionSummary.isEmpty {
                            Text(smartConnect.lastSelectionSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        // SNI field
                        HStack(spacing: 12) {
                            Text("SNI:")
                                .font(.callout)
                            TextField("rutube.ru", text: $sni)
                                .textFieldStyle(.plain)
                                .frame(maxWidth: 300)
                        }

                        // Connection status indicator
                        HStack(spacing: 10) {
                            Circle()
                                .fill(connectionColor)
                                .frame(width: 14, height: 14)
                            Text(vpnService.statusText)
                                .font(.headline)
                        }

                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if let error = vpnService.errorText {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }

                        // Connect / Disconnect
                        HStack(spacing: 18) {
                            if vpnService.isConnected {
                                Button {
                                    vpnService.disconnect()
                                } label: {
                                    Label("Disconnect", systemImage: "stop.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else {
                                Button {
                                    connectSelectedServer()
                                } label: {
                                    Label(vpnService.isConnecting ? "Connecting..." : "Connect",
                                          systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(vpnService.isConnecting || selectedServer == nil)
                            }

                            Button("Ping") {
                                vpnService.pingTunnel()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!vpnService.isConnected)
                        }

                        // Log level controls
                        HStack(spacing: 18) {
                            Picker("Log level", selection: $selectedLogLevel) {
                                Text("Warning").tag(SharedLogLevel.warning)
                                Text("Info").tag(SharedLogLevel.info)
                                Text("Debug").tag(SharedLogLevel.debug)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 450)

                            Button("Apply") {
                                vpnService.setTunnelLogLevel(selectedLogLevel)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    // No credentials — guide the user
                    VStack(spacing: 24) {
                        Image(systemName: "icloud.slash")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.secondary)

                        Text("No Credentials Found")
                            .font(.title3.bold())

                        VStack(alignment: .leading, spacing: 14) {
                            instructionRow(step: "1", icon: "iphone", text: "Open FPTN VPN on your iPhone, iPad, or Mac and log in with your token.")
                            instructionRow(step: "2", icon: "apple.logo", text: "Make sure you are signed in with the same Apple\u{00A0}ID on all devices.")
                            instructionRow(step: "3", icon: "icloud.and.arrow.down", text: "Your credentials will sync here automatically via iCloud.")
                        }
                        .padding(.horizontal, 40)

                        Button {
                            loadFromCloud()
                        } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer()
            }
            .padding(60)
            .onAppear {
                loadFromCloud()
                vpnService.syncWithSystem()
            }
            .onDisappear {
                passwordRetryTask?.cancel()
                passwordRetryTask = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .tvCloudTokenDidChange)) { _ in
                loadFromCloud()
            }
        }
    }

    private func instructionRow(step: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .frame(width: 32)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadFromCloud() {
        statusMessage = "Looking for iCloud credentials..."
        passwordRetryTask?.cancel()
        passwordRetryTask = nil

        guard var cloudToken = TvCloudTokenSync.loadTokenPayload() else {
            passwordRetryCount = 0
            isSynced = false
            statusMessage = "No credentials found in iCloud."
            return
        }

        // Restore password from iCloud Keychain.
        // Use `found` to distinguish "not synced yet" from "synced with empty password".
        let keychainResult = TvCloudTokenSync.loadPassword(username: cloudToken.username)
        if keychainResult.found {
            cloudToken = TvTokenPayload(
                version: cloudToken.version,
                service_name: cloudToken.service_name,
                username: cloudToken.username,
                password: keychainResult.password ?? "",
                servers: cloudToken.servers
            )
            passwordRetryCount = 0
            isSynced = true
            statusMessage = "Ready to connect"
        } else {
            isSynced = false
            statusMessage = "Token synced. Waiting for iCloud Keychain password..."
            schedulePasswordRetry()
        }

        token = cloudToken
        selectedServer = cloudToken.servers.first
    }

    private func schedulePasswordRetry() {
        guard passwordRetryCount < maxPasswordRetries else {
            statusMessage = "Token synced, but password not available yet. Open iOS app once to refresh keychain sync."
            return
        }

        passwordRetryCount += 1
        passwordRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: passwordRetryDelayNanos)
            guard !Task.isCancelled else { return }
            loadFromCloud()
        }
    }

    private var connectionColor: Color {
        if vpnService.isConnected {
            return .green
        } else if vpnService.isConnecting {
            return .yellow
        } else {
            return .red
        }
    }

    private func connectSelectedServer() {
        guard let token, let selectedServer else {
            statusMessage = "Select a server first"
            return
        }
        let activeSni = sni.trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = "Connecting to \(selectedServer.name)..."
        vpnService.connect(
            tokenPayload: token,
            server: selectedServer,
            sni: activeSni.isEmpty ? "rutube.ru" : activeSni,
            logLevel: selectedLogLevel
        )
    }

    private func pickBestServer() async {
        guard let token else { return }
        let best = await smartConnect.selectBestServer(from: token.servers)
        selectedServer = best
    }
}

#Preview {
    ContentView()
}

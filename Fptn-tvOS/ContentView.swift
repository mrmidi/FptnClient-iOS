import SwiftUI

struct ContentView: View {
    @State private var token: TvTokenPayload?
    @State private var selectedServer: TvVPNServer?
    @State private var isSynced = false
    @State private var statusMessage = "Looking for iCloud credentials..."

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
                        Picker("Server", selection: $selectedServer) {
                            Text("Select server").tag(Optional<TvVPNServer>.none)
                            ForEach(token.servers) { server in
                                Text("\(server.name) (\(server.host):\(server.port))")
                                    .tag(Optional(server))
                            }
                        }
                        .pickerStyle(.menu)

                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
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

        guard var cloudToken = TvCloudTokenSync.loadTokenPayload() else {
            statusMessage = "No credentials found in iCloud."
            return
        }

        // Restore password from iCloud Keychain.
        if let password = TvCloudTokenSync.loadPassword(username: cloudToken.username),
           !password.isEmpty {
            cloudToken = TvTokenPayload(
                version: cloudToken.version,
                service_name: cloudToken.service_name,
                username: cloudToken.username,
                password: password,
                servers: cloudToken.servers
            )
        }

        token = cloudToken
        selectedServer = cloudToken.servers.first
        isSynced = true
        statusMessage = "Ready to connect"
    }
}

#Preview {
    ContentView()
}

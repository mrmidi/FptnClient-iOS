import SwiftUI
import FptnSharedCore

/// The ⌘, Settings scene. Everything that used to sit inline in the main
/// window, plus the censorship-strategy picker macOS never exposed — it always
/// sent an empty string, which the native library resolved to plain SNI.
struct MacSettingsView: View {
    @EnvironmentObject private var model: MacAppModel
    @EnvironmentObject private var vpn: MacVPNService

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("Connection", systemImage: "network") }
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
    }

    // MARK: - Connection

    private var connectionTab: some View {
        Form {
            Section {
                Picker("Strategy", selection: $model.censorshipStrategy) {
                    ForEach(CensorshipStrategy.simpleCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                    Divider()
                    ForEach(CensorshipStrategy.advancedCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                TextField("SNI", text: $model.sni, prompt: Text("rutube.ru"))
            } header: {
                Text("Censorship bypass")
            } footer: {
                Text("Takes effect on the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Route push notifications through the VPN", isOn: $model.routePushThroughTunnel)
            } footer: {
                Text("Captures all traffic so APNs stays inside the tunnel. Local network access is preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A live tunnel keeps running with the settings it started with, so
        // editing them while connected is misleading rather than useful.
        .disabled(vpn.isConnected || vpn.isConnecting)
        .overlay(alignment: .bottom) {
            if vpn.isConnected || vpn.isConnecting {
                Text("Disconnect to change these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Account

    private var accountTab: some View {
        Form {
            if let token = model.token {
                LabeledContent("Service", value: token.serviceName)
                LabeledContent("Username", value: token.username)
                LabeledContent("Servers", value: "\(token.servers.count)")
            }
            Section {
                Button("Remove token…", role: .destructive) {
                    model.signOut()
                }
                .disabled(vpn.isConnected || vpn.isConnecting)
            } footer: {
                Text("You will need to paste a token again to reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

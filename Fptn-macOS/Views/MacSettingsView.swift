import SwiftUI
import FptnSharedCore
import FptnSharedTunnel

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

            // "FPTN only" and "Split routing" are both shipping product modes.
            // "Direct only" is not: it routes every flow out of this device,
            // exposing the real IP while the UI still reports a healthy
            // connection, so it stays debug-only. Hiding it is not the
            // safeguard -- MacSettingsStore.readDataPlaneMode clamps a
            // persisted value via TunnelDataPlaneMode.isReleaseSafe, and the
            // tunnel clamps again on its own side.
            Section {
                Picker("Data plane", selection: $model.dataPlaneMode) {
                    Text("FPTN only").tag(TunnelDataPlaneMode.l3Tunnel)
                    Text("Split routing").tag(TunnelDataPlaneMode.split)
                    #if DEBUG
                    Text("Direct only (unsafe)").tag(TunnelDataPlaneMode.flowProxy)
                    #endif
                }
            } footer: {
                Text("Split routing decides per flow whether traffic goes through FPTN or straight out. FPTN only sends everything through the tunnel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Log level", selection: $model.logLevel) {
                    Text("Warning").tag(SharedLogLevel.warning)
                    Text("Info").tag(SharedLogLevel.info)
                    Text("Debug").tag(SharedLogLevel.debug)
                }
            } footer: {
                Text("The periodic funnel counters are logged at Info. At Warning the tunnel looks silent even when it is working.")
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

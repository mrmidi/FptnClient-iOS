//
//  ContentView.swift
//  Fptn-macOS
//
//  Created by Aleksandr Shabelnikov on 02.03.2026.
//

import SwiftUI
import FptnSharedCore

struct ContentView: View {
    @StateObject private var vpnService = MacVPNService()
    @StateObject private var smartConnect = MacServerSelectionService()

    @State private var tokenInput: String = ""
    @State private var parsedToken: MacTokenPayload?
    @State private var selectedServer: MacVPNServer?
    @State private var sni: String = "rutube.ru"
    @State private var parserError: String?
    @State private var routePushThroughTunnel: Bool = MacSettingsStore.readRoutePushThroughTunnel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FPTN macOS")
                .font(.largeTitle.bold())

            GroupBox("Token") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $tokenInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)

                    HStack {
                        Button("Parse Token") {
                            parseToken()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Smart Connect") {
                            Task { await pickBestServer() }
                        }
                        .buttonStyle(.bordered)
                        .disabled((parsedToken?.servers.isEmpty ?? true) || smartConnect.isMeasuring)

                        if let parsedToken {
                            Text("Service: \(parsedToken.service_name)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    if !smartConnect.lastSelectionSummary.isEmpty {
                        Text(smartConnect.lastSelectionSummary)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    if let parserError {
                        Text(parserError)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Server", selection: $selectedServer) {
                        Text("Select server").tag(Optional<MacVPNServer>.none)
                        ForEach(parsedToken?.servers ?? []) { server in
                            Text("\(server.name) (\(server.host):\(server.port))")
                                .tag(Optional(server))
                        }
                    }

                    HStack {
                        Text("SNI")
                            .frame(width: 80, alignment: .leading)
                        TextField("rutube.ru", text: $sni)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Route push notifications through VPN", isOn: Binding(
                        get: { routePushThroughTunnel },
                        set: { newValue in
                            routePushThroughTunnel = newValue
                            MacSettingsStore.saveRoutePushThroughTunnel(newValue)
                        }
                    ))

                    HStack {
                        Button(vpnService.isConnected ? "Disconnect" : "Connect") {
                            vpnService.isConnected ? vpnService.disconnect() : connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vpnService.isConnecting || selectedServer == nil || parsedToken == nil)

                        Button("Ping Tunnel") {
                            vpnService.pingTunnel()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!vpnService.isConnected)
                    }
                }
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vpnService.statusText)
                        .font(.headline)
                    if let error = vpnService.errorText {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            vpnService.syncWithSystem()
            loadFromCloudIfNeeded()
        }
    }

    private func parseToken() {
        do {
            let parsed = try MacTokenParser.parse(token: tokenInput)
            parsedToken = parsed
            selectedServer = parsed.servers.first
            parserError = nil

            // Sync to iCloud so other devices get the token metadata + password.
            CloudTokenSync.saveTokenPayload(parsed)
            CloudTokenSync.savePassword(parsed.password, username: parsed.username)
        } catch {
            parserError = error.localizedDescription
            parsedToken = nil
            selectedServer = nil
        }
    }

    /// If a token was synced from another device via iCloud, load it automatically.
    private func loadFromCloudIfNeeded() {
        guard parsedToken == nil else { return }
        guard var cloudToken = CloudTokenSync.loadTokenPayload() else { return }

        // Restore password from iCloud Keychain.
        // Use `found` to accept empty passwords (token may genuinely have no password).
        let keychainResult = CloudTokenSync.loadPassword(username: cloudToken.username)
        if keychainResult.found {
            cloudToken = MacTokenPayload(
                version: cloudToken.version,
                service_name: cloudToken.service_name,
                username: cloudToken.username,
                password: keychainResult.password ?? "",
                servers: cloudToken.servers
            )
        }

        parsedToken = cloudToken
        selectedServer = cloudToken.servers.first
        tokenInput = "(synced from iCloud)"
    }

    private func connect() {
        guard let selectedServer, let parsedToken else { return }

        vpnService.connect(
            tokenPayload: parsedToken,
            server: selectedServer,
            sni: sni,
            logLevel: "warning"
        )
    }

    private func pickBestServer() async {
        guard let parsedToken else { return }
        let best = await smartConnect.selectBestServer(from: parsedToken.servers)
        await MainActor.run {
            selectedServer = best
        }
    }
}

#Preview {
    ContentView()
}

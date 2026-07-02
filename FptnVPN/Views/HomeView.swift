/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    var isCloudSynced: Bool = false
    var onLogout: () -> Void = {}
#if DEBUG
    @State private var showingDebugLog = false
#endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingServerList = false
    @State private var showingSettings = false
    @State private var showingTools = false
    @State private var showingLogs = false

    var body: some View {
        VStack {
            Spacer()

            // Connection time
            if viewModel.isConnected {
                Text("Connection Time")
                    .foregroundStyle(Color.appPrimaryText)
                Text(viewModel.connectionTimeString)
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.bottom, 10)
            }

            // Toggle button
            Button {
                withAnimation {
                    viewModel.isConnected ? viewModel.disconnect() : viewModel.connect()
                }
            } label: {
                Image(viewModel.isConnected ? "toggle_button_on" : "toggle_button_off")
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding()
            }
            .disabled(viewModel.isConnecting)

            // Status
            if viewModel.isConnecting || viewModel.isReconnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Color.appAccent)
                    Text(viewModel.isReconnecting ? "Reconnecting..." : "Connecting...")
                        .foregroundStyle(Color.appPrimaryText)
                        .font(.headline)
                }
                .padding(.bottom, 4)
            } else {
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(viewModel.isConnected ? Color.appSuccess : Color.appSecondaryText)
                    .font(.headline)
                    .padding(.bottom, 4)
            }

            // Error message
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.appError)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
#if DEBUG
                    .onLongPressGesture { showingDebugLog = true }
                    .sheet(isPresented: $showingDebugLog) { DebugLogView() }
#endif
            }

            if let runtimeStatusMessage = viewModel.runtimeStatusMessage, viewModel.errorMessage == nil {
                Text(runtimeStatusMessage)
                    .foregroundStyle(viewModel.isReconnecting ? Color.appAccent : Color.appSecondaryText)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let warningMessage = viewModel.warningMessage, !viewModel.isConnected {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warningMessage)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(Color.appAccent)
                .font(.caption)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Server name
            if viewModel.isConnected, let serverName = viewModel.selectedServerName {
                Text("Server: \(serverName)")
                    .foregroundStyle(Color.appPrimaryText)
                    .font(.subheadline)
                    .padding(.bottom, 20)
            }

            // Speed
            if viewModel.isConnected {
                HStack {
                    Image(systemName: "arrow.down.to.line.alt")
                    Text(viewModel.downloadSpeedString)
                    Spacer()
                    Text(viewModel.uploadSpeedString)
                    Image(systemName: "arrow.up.to.line.alt")
                }
                .foregroundStyle(Color.appPrimaryText)
                .padding()
                .background(Color.appElevatedSurface)
                .cornerRadius(20)
                .padding(.horizontal)
            }

            // Server selector (disconnected only)
            if !viewModel.isConnected {
                Button {
                    showingServerList = true
                } label: {
                    HStack {
                        Image(systemName: "shield")
                        Text(serverSelectionText)
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding()
                    .frame(height: 50)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.appPrimaryText)
                    .background(Color.appSurface)
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                }
                .padding(.horizontal)
                .sheet(isPresented: $showingServerList) {
                    ServerListView(viewModel: ServerListViewModel(),
                                   onSelectServer: { server in
                                       viewModel.selectServer(server)
                                   },
                                   onSelectAuto: {
                                       viewModel.setAutoMode()
                                   })
                }
            }

            Spacer()

            // iCloud sync indicator
            if isCloudSynced {
                HStack(spacing: 5) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 11))
                    Text("Token synced from iCloud")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color.appSecondaryText.opacity(0.7))
                .padding(.bottom, 8)
            }

            // Bottom navigation bar
            HStack {
                Spacer()
                VStack {
                    Image(systemName: "house.fill")
                    Text("Home").font(.caption)
                }
                Spacer()
                Button {
                    showingTools = true
                } label: {
                    VStack {
                        Image(systemName: "wrench.and.screwdriver")
                        Text("Tools").font(.caption)
                    }
                }
                .sheet(isPresented: $showingTools) {
                    ToolsView(initialConnectionMode: viewModel.connectionMode, vpnService: viewModel.vpnService)
                }
                Spacer()
                Button {
                    showingLogs = true
                } label: {
                    VStack {
                        Image(systemName: "doc.text")
                        Text("Logs").font(.caption)
                    }
                }
                .sheet(isPresented: $showingLogs) {
                    LogsView()
                }
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    VStack {
                        Image(systemName: "gear")
                        Text("Settings").font(.caption)
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(viewModel: SettingsViewModel(onLogout: onLogout))
                }
                Spacer()
            }
            .foregroundStyle(Color.appPrimaryText)
            .padding()
            .background(Color.appSurface.opacity(0.96))
        }
        .background(Color.appBackground)
        .edgesIgnoringSafeArea(.bottom)
        .navigationBarBackButtonHidden(true)
        .onAppear { viewModel.syncWithSystem() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { viewModel.syncWithSystem() }
        }
        .onChange(of: showingServerList) { _, isPresented in
            if !isPresented {
                viewModel.refreshCachedServerWarning()
            }
        }
    }

    // MARK: - Private

    private var serverSelectionText: String {
        switch viewModel.connectionMode {
        case .auto:
            return "Auto"
        case .manual(let server):
            return server.name
        }
    }
}

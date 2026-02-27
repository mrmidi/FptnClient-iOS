/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    var onLogout: () -> Void = {}
#if DEBUG
    @State private var showingDebugLog = false
#endif
    @State private var showingServerList = false
    @State private var showingSettings = false

    var body: some View {
        VStack {
            Spacer()

            // Connection time
            if viewModel.isConnected {
                Text("Connection Time")
                    .foregroundColor(.white)
                Text(viewModel.connectionTimeString)
                    .foregroundColor(.white)
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
            .padding(.top, -200)

            // Status
            Text(viewModel.isConnected ? "Connected" : "Disconnected")
                .foregroundColor(viewModel.isConnected ? .yellow : .gray)
                .font(.headline)
                .padding(.bottom, 4)
#if DEBUG
                .onLongPressGesture { showingDebugLog = true }
                .sheet(isPresented: $showingDebugLog) { DebugLogView() }
#endif

            // Server name
            if viewModel.isConnected, let serverName = viewModel.selectedServerName {
                Text("Server: \(serverName)")
                    .foregroundColor(.white)
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
                .foregroundColor(.white)
                .padding()
                .background(Color.purple.opacity(0.3))
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
                    .background(Color.white)
                    .cornerRadius(20)
                    .shadow(radius: 2)
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

            // Bottom navigation bar
            HStack {
                Spacer()
                VStack {
                    Image(systemName: "house.fill")
                    Text("Home").font(.caption)
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
                // TODO: Uncomment when app is on App Store for sharing/promotion
                // VStack {
                //     Image(systemName: "square.and.arrow.up")
                //     Text("Share").font(.caption)
                // }
                // Spacer()
            }
            .foregroundColor(.white)
            .padding()
            .background(Color.black.opacity(0.9))
        }
        .background(Color.appBackground)
        .edgesIgnoringSafeArea(.bottom)
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

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: DPI Bypass

                Section {
                    Picker("Method", selection: Binding(
                        get: { viewModel.bypassMethod },
                        set: { viewModel.saveBypassMethod($0) }
                    )) {
                        ForEach(BypassMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .foregroundColor(.white)

                    if viewModel.bypassMethod.requiresSNI {
                        TextField("e.g. rutube.ru", text: $viewModel.sni)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .foregroundColor(.white)
                            .onSubmit { viewModel.saveSni() }
                            .onChange(of: viewModel.sni) { _, _ in viewModel.saveSni() }
                    }
                } header: {
                    Text("DPI Bypass")
                        .foregroundColor(Color.cian)
                } footer: {
                    Group {
                        switch viewModel.bypassMethod {
                        case .sniSpoofing:
                            Text("SNI Spoofing: disguises VPN traffic by sending a fake SNI hostname during the TLS handshake.")
                        case .obfuscation:
                            Text("TLS Obfuscation: wraps traffic to resist deep-packet inspection. No SNI hostname needed.")
                        case .sniReality:
                            Text("SNI + REALITY: combines SNI spoofing with the REALITY protocol for stronger censorship resistance.")
                        }
                    }
                    .foregroundColor(.gray)
                }

                // MARK: Connection

                Section {
                    Toggle(isOn: Binding(
                        get: { viewModel.autoConnect },
                        set: { viewModel.saveAutoConnect($0) }
                    )) {
                        Text("Auto-Connect on Launch")
                            .foregroundColor(.white)
                    }
                    .tint(Color.cian)

                    Toggle(isOn: Binding(
                        get: { viewModel.reconnectEnabled },
                        set: { viewModel.saveReconnectEnabled($0) }
                    )) {
                        Text("Auto-Reconnect on Drop")
                            .foregroundColor(.white)
                    }
                    .tint(Color.cian)

                    if viewModel.reconnectEnabled {
                        Stepper(
                            value: Binding(
                                get: { viewModel.maxReconnectAttempts },
                                set: { viewModel.saveMaxReconnectAttempts($0) }
                            ),
                            in: 0...25
                        ) {
                            HStack {
                                Text("Max attempts")
                                    .foregroundColor(.white)
                                Spacer()
                                Text(viewModel.maxReconnectAttempts == 0 ? "∞" : "\(viewModel.maxReconnectAttempts)")
                                    .foregroundColor(Color.cian)
                            }
                        }

                        Stepper(
                            value: Binding(
                                get: { viewModel.reconnectDelay },
                                set: { viewModel.saveReconnectDelay($0) }
                            ),
                            in: 1...60
                        ) {
                            HStack {
                                Text("Retry delay")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(viewModel.reconnectDelay)s")
                                    .foregroundColor(Color.cian)
                            }
                        }
                    }
                } header: {
                    Text("Connection")
                        .foregroundColor(Color.cian)
                }

                // MARK: Per-App VPN

                Section {
                    NavigationLink {
                        AppFilterView()
                    } label: {
                        Text("Per-App VPN")
                            .foregroundColor(.white)
                    }
                } header: {
                    Text("Routing")
                        .foregroundColor(Color.cian)
                } footer: {
                    Text("Restrict VPN to specific apps or exclude selected apps from the tunnel.")
                        .foregroundColor(.gray)
                }

                // MARK: Account

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Log Out")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                } header: {
                    Text("Account")
                        .foregroundColor(Color.cian)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.cian)
                }
            }
        }
        .confirmationDialog(
            "Are you sure you want to log out?",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                dismiss()
                viewModel.logout()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel())
        .preferredColorScheme(.dark)
}

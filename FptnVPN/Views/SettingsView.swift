/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirmation = false
    @State private var showClearKeychainConfirmation = false
    @State private var showAdvancedBypass = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Appearance

                Section {
                    Picker("Color Scheme", selection: Binding(
                        get: { viewModel.colorScheme },
                        set: { viewModel.saveColorScheme($0) }
                    )) {
                        ForEach(AppColorScheme.allCases) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.appAccent)
                } header: {
                    Text("Appearance")
                        .foregroundStyle(Color.appAccent)
                }
                .listRowBackground(Color.appSurface)

                // MARK: DPI Bypass

                Section {
                    Picker("Method", selection: Binding(
                        get: { viewModel.bypassMethod },
                        set: { viewModel.saveBypassMethod($0) }
                    )) {
                        ForEach(primaryBypassMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.appAccent)

                    DisclosureGroup("Advanced Profiles", isExpanded: $showAdvancedBypass) {
                        Picker("Profile", selection: Binding(
                            get: { viewModel.bypassMethod.isAdvanced ? viewModel.bypassMethod : .sniRealityChrome147 },
                            set: { viewModel.saveBypassMethod($0) }
                        )) {
                            ForEach(CensorshipStrategy.advancedCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.appAccent)
                    }

                    if viewModel.bypassMethod.requiresSNI {
                        TextField("e.g. rutube.ru", text: $viewModel.sni)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .foregroundStyle(Color.appPrimaryText)
                            .padding(.vertical, 6)
                            .onSubmit { viewModel.saveSni() }
                            .onChange(of: viewModel.sni) { _, _ in viewModel.saveSni() }
                    }
                } header: {
                    Text("DPI Bypass")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text(viewModel.bypassMethod.helpText)
                    .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Connection

                Section {
                    Toggle(isOn: Binding(
                        get: { viewModel.autoConnect },
                        set: { viewModel.saveAutoConnect($0) }
                    )) {
                        Text("Auto-Connect on Launch")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .tint(Color.appAccent)

                    Toggle(isOn: Binding(
                        get: { viewModel.reconnectEnabled },
                        set: { viewModel.saveReconnectEnabled($0) }
                    )) {
                        Text("Auto-Reconnect on Drop")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .tint(Color.appAccent)

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
                                    .foregroundStyle(Color.appPrimaryText)
                                Spacer()
                                Text(viewModel.maxReconnectAttempts == 0 ? "∞" : "\(viewModel.maxReconnectAttempts)")
                                    .foregroundStyle(Color.appAccent)
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
                                    .foregroundStyle(Color.appPrimaryText)
                                Spacer()
                                Text("\(viewModel.reconnectDelay)s")
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                    }

                    Stepper(
                        value: Binding(
                            get: { viewModel.websocketIdleTimeoutSeconds },
                            set: { viewModel.saveWebsocketIdleTimeoutSeconds($0) }
                        ),
                        in: 5...300,
                        step: 5
                    ) {
                        HStack {
                            Text("Tunnel idle timeout")
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer()
                            Text("\(viewModel.websocketIdleTimeoutSeconds)s")
                                .foregroundStyle(Color.appAccent)
                        }
                    }

                } header: {
                    Text("Connection")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text("Runtime reconnect now happens inside the packet tunnel provider. Auto-Reconnect controls the retry budget and delay, while Tunnel idle timeout controls how quickly the websocket is treated as dead.")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Logging

                Section {
                    Picker("Log Level", selection: Binding(
                        get: { viewModel.logLevel },
                        set: { viewModel.saveLogLevel($0) }
                    )) {
                        ForEach(LogLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.appAccent)
                } header: {
                    Text("Logging")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text("Default is Warning. Use Debug only for troubleshooting because it can produce high-volume logs.")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Routing

                Section {
                    Toggle(isOn: Binding(
                        get: { viewModel.routePushThroughTunnel },
                        set: { viewModel.saveRoutePushThroughTunnel($0) }
                    )) {
                        Text("Route Push Notifications")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .tint(Color.appAccent)
                } header: {
                    Text("Routing")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text("Route Push Notifications forces Apple Push (APNs) traffic through the tunnel so notifications keep arriving on networks that block them directly. This routes all network traffic through the VPN while connected.")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Account

                Section {
                    Button(role: .destructive) {
                        showClearKeychainConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Clear Keychain Credentials")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
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
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text("Clear Keychain removes the stored password from iCloud Keychain on all devices. The app will re-sync it automatically on next launch.")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.appAccent)
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
        .confirmationDialog(
            "Clear Keychain Credentials?",
            isPresented: $showClearKeychainConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                viewModel.clearKeychain()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the stored password from iCloud Keychain on all devices. The app will re-sync it on next launch.")
        }
    }

    private var primaryBypassMethods: [CensorshipStrategy] {
        if viewModel.bypassMethod.isAdvanced {
            return CensorshipStrategy.simpleCases + [viewModel.bypassMethod]
        }
        return CensorshipStrategy.simpleCases
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel())
}

#Preview("Settings Light") {
    SettingsView(viewModel: SettingsViewModel())
        .preferredColorScheme(.light)
}

#Preview("Settings Dark") {
    SettingsView(viewModel: SettingsViewModel())
        .preferredColorScheme(.dark)
}

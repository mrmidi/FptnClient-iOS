/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import FptnSharedTunnel

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirmation = false
    @State private var showClearKeychainConfirmation = false
    @State private var showGeoDatabase = false
    @State private var showAdvancedBypass = false

    private var dataPlaneFooter: String {
        switch viewModel.dataPlaneMode {
        case .l3Tunnel:
            "All traffic goes through the FPTN server."
        case .split:
            "Decides each connection separately from the geo database: listed Russian, Apple, Microsoft and gaming destinations leave directly from this device, ad and tracker domains are blocked, and everything else goes through the server. With no database loaded, everything goes through the server."
        case .flowProxy:
            "Every flow exits from this device, NOT through an FPTN server — your real IP is not hidden. Profiling only."
        }
    }

    /// The app and the native framework are compiled separately, so the pair
    /// has to be reported as a pair — a Release app linked against a Debug
    /// framework looks entirely healthy from the outside.
    private var buildFooter: String {
        let base = "The app and the native protocol library are built separately. "
            + "Built \(NativeBuildInfo.buildTimestamp)."
        guard NativeBuildInfo.hasMixedConfiguration else { return base }
        return base + " The app is \(NativeBuildInfo.swiftConfiguration) but the "
            + "library is \(NativeBuildInfo.configuration)."
    }

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
                            .onChange(of: viewModel.sni) { _ in viewModel.saveSni() }
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

                    Toggle(isOn: Binding(
                        get: { viewModel.customDnsEnabled },
                        set: { viewModel.saveCustomDnsEnabled($0) }
                    )) {
                        Text("Custom DNS")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .tint(Color.appAccent)

                    if viewModel.customDnsEnabled {
                        TextField("e.g. 8.8.8.8", text: $viewModel.customDnsIPv4)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundStyle(Color.appPrimaryText)
                            .padding(.vertical, 6)
                            .onChange(of: viewModel.customDnsIPv4) { newValue in
                                let filtered = newValue.filter { $0.isNumber || $0 == "." }
                                if filtered != newValue { viewModel.customDnsIPv4 = filtered }
                                viewModel.saveCustomDnsIPv4(filtered)
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
                    Text("Sends Apple Push (APNs) through the server, so notifications keep arriving on networks that block Apple's addresses directly. While connected this forces all traffic through the VPN. In split routing it makes push the one Apple service that does not go direct — updates and iCloud still do.")
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Build
                //
                // Not debug-only on purpose. The failure this exists to catch —
                // an optimised app linked against a Debug native framework — is
                // exactly the one that survives into a TestFlight build and
                // silently invalidates any measurement taken from it.

                Section {
                    LabeledContent("Native Library") {
                        Text("\(NativeBuildInfo.configuration) \(NativeBuildInfo.optimizationLevel)")
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    LabeledContent("Platform") {
                        Text(NativeBuildInfo.platform)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    LabeledContent("App") {
                        Text(NativeBuildInfo.swiftConfiguration)
                            .foregroundStyle(
                                NativeBuildInfo.hasMixedConfiguration
                                    ? Color.orange : Color.appSecondaryText
                            )
                    }
                    LabeledContent("Native Commit") {
                        Text(NativeBuildInfo.fptnCommit)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    if let caveat = NativeBuildInfo.performanceCaveat {
                        Label(caveat, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                            .font(.footnote)
                    }
                } header: {
                    Text("Build")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text(buildFooter)
                        .foregroundStyle(Color.appSecondaryText)
                }
                .listRowBackground(Color.appSurface)

                // MARK: Traffic Routing

                // "FPTN only" and "Split routing" are both shipping product
                // modes and are offered in every build. "Direct only" is not:
                // it routes every flow out of this device, exposing the real IP
                // while the UI still reports a healthy connection, so it stays
                // debug-only. Hiding it is not the safeguard — a value a debug
                // build persisted is clamped back to FPTN only by
                // SettingsService.dataPlaneMode via TunnelDataPlaneMode
                // .isReleaseSafe, which is what actually enforces this.
                Section {
                    Picker(selection: Binding(
                        get: { viewModel.dataPlaneMode },
                        set: { viewModel.saveDataPlaneMode($0) }
                    )) {
                        Text("FPTN only").tag(TunnelDataPlaneMode.l3Tunnel)
                        Text("Split routing").tag(TunnelDataPlaneMode.split)
                        #if DEBUG
                        Text("Direct only (unsafe)").tag(TunnelDataPlaneMode.flowProxy)
                        #endif
                    } label: {
                        Text("Data Plane")
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .tint(Color.appAccent)

                    Button {
                        showGeoDatabase = true
                    } label: {
                        HStack {
                            Text("Geo Database")
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                } header: {
                    Text("Traffic Routing")
                        .foregroundStyle(Color.appAccent)
                } footer: {
                    Text(dataPlaneFooter)
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
        .sheet(isPresented: $showGeoDatabase) {
            GeoDatabaseView()
        }
        .alert(
            "Routing policy unavailable",
            isPresented: Binding(
                get: { viewModel.geoProvisionFailure != nil },
                set: { if !$0 { viewModel.geoProvisionFailure = nil } }
            )
        ) {
            Button("Open Geo Database") {
                viewModel.geoProvisionFailure = nil
                showGeoDatabase = true
            }
            Button("Later", role: .cancel) {
                viewModel.geoProvisionFailure = nil
            }
        } message: {
            // Says what it means for the person, not what failed. Split routing
            // stays selected and keeps working either way — with no policy
            // every flow takes the default verdict, which is the server. The
            // advice differs: a blocked download is worth retrying over the
            // tunnel, a policy that cannot be built will fail the same way
            // however it is fetched.
            switch viewModel.geoProvisionFailureReason {
            case .policy:
                Text("The routing lists were downloaded but could not be prepared, so all traffic will go through FPTN servers. Split routing stays on. This usually clears up with the next published update.")
            case .download, nil:
                Text("The routing lists could not be downloaded, so all traffic will go through FPTN servers. Split routing stays on. Your network may be blocking the download — try again from the Geo Database screen while the VPN is connected.")
            }
        }
        .alert(
            "Push routing not applied",
            isPresented: $viewModel.geoPolicyRebuildFailed
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            // Deliberately not the "everything goes through FPTN servers"
            // warning: the previously published policy is intact and still
            // routing. The only thing that failed is the change.
            Text("The split-routing policy could not be rebuilt, so push notifications still follow the previous setting. Updating the database from the Geo Database screen will apply it.")
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

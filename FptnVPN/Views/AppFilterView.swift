/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct AppFilterView: View {
    @State private var mode: PerAppVPNMode = AppFilterService.shared.mode
    @State private var apps: [AppFilter] = []

    var body: some View {
        List {
            // MARK: Mode picker

            Section {
                Picker("Mode", selection: $mode) {
                    Text("Off").tag(PerAppVPNMode.off)
                    Text("Only these apps").tag(PerAppVPNMode.onlyAllowed)
                    Text("All except").tag(PerAppVPNMode.exceptDisallowed)
                }
                .pickerStyle(.inline)
                .foregroundColor(.white)
                .onChange(of: mode) { _, newMode in
                    Task { await AppFilterService.shared.setMode(newMode) }
                }
            } header: {
                Text("Per-App VPN Mode")
                    .foregroundColor(Color.cian)
            } footer: {
                Group {
                    switch mode {
                    case .off:
                        Text("VPN applies to all apps.")
                    case .onlyAllowed:
                        Text("VPN applies only to the selected apps.")
                    case .exceptDisallowed:
                        Text("VPN applies to all apps except the selected ones.")
                    }
                }
                .foregroundColor(.gray)
            }

            // MARK: App list (visible when mode ≠ off)

            if mode != .off {
                Section {
                    ForEach($apps) { $app in
                        Toggle(isOn: $app.isSelected) {
                            Text(app.displayName)
                                .foregroundColor(.white)
                        }
                        .tint(Color.cian)
                        .onChange(of: app.isSelected) { _, _ in
                            Task { await AppFilterService.shared.saveApps(apps) }
                        }
                    }
                } header: {
                    Text("Apps")
                        .foregroundColor(Color.cian)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Per-App VPN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            Task { apps = await AppFilterService.shared.loadApps() }
        }
    }
}

#Preview {
    NavigationStack {
        AppFilterView()
    }
    .preferredColorScheme(.dark)
}

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct ServerListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: ServerListViewModel

    // Callback to notify HomeViewModel of selection
    var onSelectServer: ((VPNServer) -> Void)?
    var onSelectAuto: (() -> Void)?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Connection Mode")) {
                    Button {
                        onSelectAuto?()
                        dismiss()
                    } label: {
                        HStack {
                            Text("Auto")
                            Spacer()
                        }
                    }
                }

                Section(header: Text("Servers")) {
                    ForEach(viewModel.servers) { server in
                        Button {
                            onSelectServer?(server)
                            dismiss()
                        } label: {
                            Text(server.name)
                        }
                    }
                }
            }
            .navigationTitle("Select Server")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .task {
                await viewModel.loadServers()
            }
        }
    }
}

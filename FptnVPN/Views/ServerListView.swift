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
                            Text(viewModel.autoSummaryText)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }

                Section(header: Text("Servers")) {
                    ForEach(viewModel.rows) { row in
                        Button {
                            onSelectServer?(row.server)
                            dismiss()
                        } label: {
                            HStack {
                                Text(row.server.name)
                                Spacer()
                                Text(row.latencyText)
                                    .foregroundStyle(row.isReachable ? Color.appSuccess : Color.appSecondaryText)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Server")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .overlay(alignment: .top) {
                if let progress = viewModel.progress, viewModel.isRefreshing {
                    Text("Checking \(progress.done)/\(progress.total) servers")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.appSurface)
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }
            }
            .refreshable {
                await viewModel.refreshServers()
            }
            .task {
                await viewModel.loadServers()
            }
        }
    }
}

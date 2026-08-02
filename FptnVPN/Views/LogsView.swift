/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import UIKit

struct LogsView: View {
    @StateObject private var viewModel = LogsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                controls
                logList
            }
            .padding()
            .background(Color.appBackground)
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(viewModel.isFollowing ? "Pause" : "Follow") {
                        viewModel.isFollowing.toggle()
                    }
                    .foregroundStyle(Color.appAccent)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string = viewModel.exportFilteredText()
                    }
                    .foregroundStyle(Color.appAccent)

                    Button("Clear") {
                        viewModel.clear()
                    }
                    .foregroundStyle(Color.appAccent)

                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(Color.appAccent)
                }
            }
            .onAppear { viewModel.start() }
            .onDisappear { viewModel.stop() }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Level")
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
                Picker("Level", selection: Binding(
                    get: { viewModel.selectedLevel },
                    set: { viewModel.saveLogLevel($0) }
                )) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.appAccent)
            }

            Picker("Source", selection: $viewModel.selectedSource) {
                ForEach(LogsViewModel.SourceFilter.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .tint(Color.appAccent)

            Toggle("Recent only (24h)", isOn: $viewModel.showRecentOnly)
                .tint(Color.appAccent)
                .font(.caption)
                .foregroundStyle(Color.appSecondaryText)

            HStack {
                Text("Shown: \(viewModel.filteredEntries.count)")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
                Text("Default: Warning")
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if viewModel.filteredEntries.isEmpty {
                        Text("No logs for selected filters")
                            .font(.caption)
                            .foregroundStyle(Color.appSecondaryText)
                            .padding(.top, 8)
                    }

                    ForEach(viewModel.filteredEntries) { entry in
                        Text(entry.raw)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                            .id(entry.id)
                    }
                }
                .padding(10)
            }
            .background(Color.appSurface)
            .cornerRadius(12)
            .onChange(of: viewModel.filteredEntries.count) { _ in
                guard viewModel.isFollowing, let last = viewModel.filteredEntries.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func color(for entry: LogsViewModel.LogEntry) -> Color {
        switch entry.level {
        case .warning:
            if entry.raw.contains("❌") || entry.raw.contains("💥") { return .red }
            return .orange
        case .info:
            return entry.source == .tunnel ? .cyan : Color.appPrimaryText
        case .debug:
            return Color.appSecondaryText
        }
    }
}

#Preview {
    LogsView()
}

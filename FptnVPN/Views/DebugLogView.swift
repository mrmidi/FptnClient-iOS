/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#if DEBUG
import SwiftUI

/// In-app log viewer that tails the shared App Group log file.
/// Shows interleaved lines from both the app and FptnVPNTunnel processes.
/// Access: long-press the status text on HomeView.
@MainActor
struct DebugLogView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var isAutoScrolling = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.filteredEntries) { entry in
                            Text(entry.raw)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(lineColor(for: entry.raw))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.filteredEntries.count) { _ in
                    if isAutoScrolling, let last = viewModel.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        viewModel.clear()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isAutoScrolling ? "Pause" : "Follow") {
                        isAutoScrolling.toggle()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                viewModel.selectedSource = .all
                viewModel.selectedLevel = .debug // Debug view defaults to showing debug logs
                viewModel.start()
            }
            .onDisappear {
                viewModel.stop()
            }
        }
    }

    // MARK: - Private

    private func lineColor(for line: String) -> Color {
        if line.contains("💥") || line.contains("❌") { return .red }
        if line.contains("⚠️") { return .orange }
        if line.contains("[org.fptn.tunnel]") { return .cyan }
        if line.contains("🔍") { return Color(white: 0.5) }
        return .white
    }
}

#Preview {
    DebugLogView()
}
#endif

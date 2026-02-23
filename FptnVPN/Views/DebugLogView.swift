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
    @State private var logContent: String = ""
    @State private var isAutoScrolling = true
    @Environment(\.dismiss) private var dismiss

    private let refreshInterval: TimeInterval = 1.0

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let lines = logContent.components(separatedBy: "\n").filter { !$0.isEmpty }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(lineColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: logContent) { _, _ in
                    if isAutoScrolling {
                        let lines = logContent.components(separatedBy: "\n").filter { !$0.isEmpty }
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        SharedLogSink.shared.clear()
                        logContent = ""
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
            .task {
                await startRefreshing()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Private

    private func startRefreshing() async {
        while !Task.isCancelled {
            logContent = SharedLogSink.shared.readAll()
            try? await Task.sleep(for: .seconds(refreshInterval))
        }
    }

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

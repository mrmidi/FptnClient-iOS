/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI
import UIKit

// MARK: - ProbeStatus display helpers

private extension ProbeStatus {
    var badgeColor: Color {
        switch self {
        case .reachable:   return Color.appSuccess
        case .unreachable: return Color.appError
        }
    }

    var label: String { rawValue }
}

// MARK: - Result row

private struct ProbeResultRow: View {
    let result: ProbeResult

    var body: some View {
        HStack(spacing: 10) {
            // Latency pill
            if result.status == .reachable {
                Text("\(result.latencyMs)ms")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appSuccess)
                    .clipShape(Capsule())
            } else {
                Text("—")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appError)
                    .clipShape(Capsule())
            }

            Text(result.sni)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color.appPrimaryText)

            Spacer(minLength: 4)

            Text(result.detail)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(Color.appSecondaryText)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail sheet

private struct ProbeDetailSheet: View {
    let result: ProbeResult
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                field("SNI", value: result.sni)
                field("Status", value: result.status.rawValue)
                if result.latencyMs >= 0 {
                    field("Latency", value: "\(result.latencyMs) ms")
                }
                field("Detail", value: result.detail)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(result.sni)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Apply as SNI") {
                        onApply()
                        dismiss()
                    }
                    .foregroundStyle(Color.appAccent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.appAccent)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ title: String, value: String) -> some View {
        Section(title) {
            Text(value)
                .foregroundStyle(Color.appPrimaryText)
                .font(.system(.body, design: .monospaced))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = value
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        }
        .listRowBackground(Color.appSurface)
    }
}

// MARK: - Advanced settings panel

private struct AdvancedSettingsView: View {
    @Binding var concurrency: Int
    @Binding var timeoutMs: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Concurrency")
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer()
                    Text("\(concurrency)")
                        .foregroundStyle(Color.appAccent)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(concurrency) },
                        set: { concurrency = max(1, Int($0)) }
                    ),
                    in: 1...20,
                    step: 1
                )
                .tint(Color.appAccent)
            }

            Stepper(
                value: Binding(
                    get: { timeoutMs / 1000 },
                    set: { timeoutMs = $0 * 1000 }
                ),
                in: 1...30,
                step: 1
            ) {
                HStack {
                    Text("Timeout")
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer()
                    Text("\(timeoutMs / 1000)s")
                        .foregroundStyle(Color.appAccent)
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .background(Color.appSurface)
        .cornerRadius(12)
    }
}

// MARK: - Main view

struct SNICheckerView: View {
    @StateObject private var viewModel: SNIScannerViewModel
    @State private var selectedResult: ProbeResult?
    @State private var isAdvancedExpanded = false

    init(initialConnectionMode: VPNConnection.ConnectionMode = .auto) {
        _viewModel = StateObject(
            wrappedValue: SNIScannerViewModel(initialConnectionMode: initialConnectionMode)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Server + Method pickers
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Server")
                            .font(.subheadline)
                            .foregroundStyle(Color.appSecondaryText)
                            .frame(width: 60, alignment: .leading)
                        if viewModel.servers.isEmpty {
                            Text("No servers")
                                .foregroundStyle(Color.appSecondaryText)
                                .font(.subheadline)
                        } else {
                            Picker("Server", selection: $viewModel.selectedServer) {
                                ForEach(viewModel.servers) { server in
                                    Text(server.name).tag(Optional(server))
                                }
                            }
                            .pickerStyle(.menu)
                            .foregroundStyle(Color.appAccent)
                        }
                    }

                    HStack {
                        Text("Method")
                            .font(.subheadline)
                            .foregroundStyle(Color.appSecondaryText)
                            .frame(width: 60, alignment: .leading)
                        Picker("Method", selection: $viewModel.bypassMethod) {
                            ForEach(BypassMethod.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: SNI input
                VStack(alignment: .leading, spacing: 6) {
                    Text("SNI List")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.appSecondaryText)

                    TextEditor(text: $viewModel.sniInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(8)
                        .background(Color.appSurface)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.appSeparator, lineWidth: 1)
                        )
                        .overlay(
                            Group {
                                if viewModel.sniInput.isEmpty {
                                    Text("Paste SNI hostnames, one per line…\n# lines starting with # are ignored")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(Color.appSecondaryText.opacity(0.6))
                                        .padding(14)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )

                    HStack {
                        if viewModel.parsedCount > 0 {
                            Text("\(viewModel.parsedCount) domain\(viewModel.parsedCount == 1 ? "" : "s") parsed")
                                .font(.caption)
                                .foregroundStyle(Color.appAccent)
                        } else {
                            Text("No domains")
                                .font(.caption)
                                .foregroundStyle(Color.appSecondaryText)
                        }
                        Spacer()
                    }
                }

                // MARK: Start / Stop
                Button {
                    viewModel.isScanning ? viewModel.stopScan() : viewModel.startScan()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: viewModel.isScanning ? "stop.fill" : "play.fill")
                        Text(viewModel.isScanning ? "Stop" : "Start Scan")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .frame(height: 48)
                    .background(viewModel.isScanning ? Color.appError : Color.appAccent)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .disabled(!viewModel.isScanning && (viewModel.parsedCount == 0 || viewModel.selectedServer == nil))

                // MARK: Progress
                if let p = viewModel.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .tint(Color.appAccent)

                        HStack(spacing: 12) {
                            statChip(label: "REACHABLE", count: p.reachable, color: Color.appSuccess)
                            statChip(label: "UNREACHABLE", count: p.unreachable, color: Color.appError)
                            Spacer()
                            Text("\(p.done) / \(p.total)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                } else if viewModel.isScanning {
                    ProgressView()
                        .tint(Color.appAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // MARK: Best result banner
                if let best = viewModel.bestResult {
                    HStack(spacing: 10) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Best")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.appSecondaryText)
                            Text(best.sni)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(best.latencyMs)ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.appSuccess)
                        Button {
                            viewModel.applyBestSNI()
                        } label: {
                            Label("Apply", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.appAccent)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(12)
                    .background(Color.appSurface)
                    .cornerRadius(12)
                }

                // MARK: Filter + results
                if !viewModel.results.isEmpty {
                    Toggle("Show reachable only", isOn: $viewModel.showOnlyReachable)
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                        .tint(Color.appAccent)

                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredResults) { result in
                            Button {
                                selectedResult = result
                            } label: {
                                ProbeResultRow(result: result)
                                    .padding(.horizontal, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = result.sni
                                } label: {
                                    Label("Copy SNI", systemImage: "doc.on.doc")
                                }
                                Button {
                                    viewModel.applySNI(result.sni)
                                } label: {
                                    Label("Apply as SNI", systemImage: "checkmark.circle")
                                }
                            }

                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                    .background(Color.appSurface)
                    .cornerRadius(12)
                }

                // MARK: Advanced settings
                DisclosureGroup(
                    isExpanded: $isAdvancedExpanded,
                    content: {
                        AdvancedSettingsView(
                            concurrency: $viewModel.concurrency,
                            timeoutMs: $viewModel.timeoutMs
                        )
                        .padding(.top, 8)
                    },
                    label: {
                        Text("Advanced")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.appSecondaryText)
                    }
                )
                .accentColor(Color.appAccent)
            }
            .padding()
        }
        .background(Color.appBackground)
        .sheet(item: $selectedResult) { result in
            ProbeDetailSheet(result: result) {
                viewModel.applySNI(result.sni)
            }
        }
    }

    @ViewBuilder
    private func statChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

#Preview {
    SNICheckerView()
}

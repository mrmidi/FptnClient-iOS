/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class SNIScannerViewModel: ObservableObject {
    // MARK: - Input

    @Published var sniInput: String = ""

    // MARK: - Server selection

    @Published var servers: [VPNServer] = []
    @Published var selectedServer: VPNServer?

    // MARK: - Config

    @Published var bypassMethod: BypassMethod = SettingsService.shared.bypassMethod
    @Published var timeoutMs: Int = 5000
    @Published var concurrency: Int = 5

    // MARK: - State

    @Published private(set) var results: [ProbeResult] = []
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var bestResult: ProbeResult?
    @Published var showVPNDisconnectConfirm = false

    // MARK: - VPN state

    var vpnIsActive: Bool {
        vpnService?.connection.isConnected == true ||
        vpnService?.connection.isConnecting == true
    }

    // MARK: - Filter

    @Published var showOnlyReachable = false

    // MARK: - Computed

    var filteredResults: [ProbeResult] {
        let base = results.sorted {
            if $0.status != $1.status { return $0.status == .reachable }
            return $0.latencyMs < $1.latencyMs
        }
        return showOnlyReachable ? base.filter { $0.status == .reachable } : base
    }

    var parsedCount: Int { ScannerEngine.sanitize(sniInput).count }

    // MARK: - Private

    private let engine = ScannerEngine()
    private var scanTask: Task<Void, Never>?
    private var resultBuffer: [ProbeResult] = []
    private var currentBest: ProbeResult?
    private weak var vpnService: VPNService?

    // MARK: - Init

    init(initialConnectionMode: VPNConnection.ConnectionMode = .auto, vpnService: VPNService? = nil) {
        self.vpnService = vpnService
        Task {
            let all = await TokenService.shared.getServers()
            servers = all
            switch initialConnectionMode {
            case .auto:
                selectedServer = all.first
            case .manual(let s):
                selectedServer = s
            }
        }
    }

    // MARK: - Actions

    func startScan() {
        guard selectedServer != nil, !isScanning else { return }
        if vpnIsActive {
            showVPNDisconnectConfirm = true
            return
        }
        performScan()
    }

    /// Called when user confirms "disconnect VPN and scan".
    func disconnectAndStartScan() {
        guard selectedServer != nil else { return }
        vpnService?.disconnect()
        results = []; resultBuffer = []; progress = nil
        bestResult = nil; currentBest = nil; isScanning = true

        scanTask = Task { [weak self] in
            guard let self else { return }
            // Give the tunnel ~1 s to tear down its TUN interface before sending
            // direct probes — otherwise early connections still route through the tunnel.
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { self.performScan() }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        flushBuffer()
        isScanning = false
    }

    func applyBestSNI() {
        guard let best = bestResult else { return }
        let clean = SettingsService.sanitizeSNI(best.sni)
        guard !clean.isEmpty else { return }
        Task { await SettingsService.shared.setSni(clean) }
    }

    func applySNI(_ sni: String) {
        let clean = SettingsService.sanitizeSNI(sni)
        guard !clean.isEmpty else { return }
        Task { await SettingsService.shared.setSni(clean) }
    }

    // MARK: - Private

    private func performScan() {
        guard let server = selectedServer, !isScanning else { return }
        results = []; resultBuffer = []; progress = nil
        bestResult = nil; currentBest = nil; isScanning = true

        let cfg = ProbeConfig(
            server: server,
            bypassMethod: bypassMethod,
            timeoutMs: timeoutMs,
            concurrency: concurrency
        )
        let snis = ScannerEngine.sanitize(sniInput)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.runScan(snis: snis, cfg: cfg)
            for await event in stream {
                if Task.isCancelled { break }
                await MainActor.run { self.handle(event: event) }
            }
        }
    }

    private func handle(event: ScanEvent) {
        switch event {
        case .result(let r):
            resultBuffer.append(r)
            if r.status == .reachable {
                if currentBest == nil || r.latencyMs < currentBest!.latencyMs {
                    currentBest = r
                    bestResult = r
                }
            }
            if resultBuffer.count >= 20 { flushBuffer() }
        case .progress(let p):
            progress = p
        case .finished:
            flushBuffer()
            isScanning = false
        }
    }

    private func flushBuffer() {
        guard !resultBuffer.isEmpty else { return }
        results.append(contentsOf: resultBuffer)
        resultBuffer.removeAll()
    }
}

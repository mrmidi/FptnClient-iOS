import SwiftUI

/// The main window once a token exists: what state the tunnel is in, which
/// server it will use, and one button.
struct ConnectionView: View {
    @EnvironmentObject private var model: MacAppModel
    @EnvironmentObject private var vpn: MacVPNService
    @EnvironmentObject private var selection: MacServerSelectionService

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Status

    private var statusHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: vpn.isConnected ? "lock.shield.fill" : "lock.open")
                .font(.system(size: 40))
                .foregroundStyle(vpn.isConnected ? Color.accentColor : .secondary)
                .symbolRenderingMode(.hierarchical)

            Text(vpn.statusText)
                .font(.title3.weight(.semibold))

            if let server = model.selectedServer, vpn.isConnected {
                Text(server.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = vpn.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Picker("Server", selection: serverBinding) {
                    ForEach(model.servers) { server in
                        Text(server.name).tag(Optional(server))
                    }
                }
                .labelsHidden()
                // Changing servers mid-session would silently keep the old one
                // running until the next reconnect.
                .disabled(vpn.isConnected || vpn.isConnecting)

                Button {
                    Task { await pickFastest() }
                } label: {
                    if selection.isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fastest")
                    }
                }
                .disabled(model.servers.isEmpty || selection.isMeasuring || vpn.isConnected)
                .help("Measure every server and select the one with the lowest latency")
            }

            if !selection.lastSelectionSummary.isEmpty {
                Text(selection.lastSelectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                vpn.isConnected ? vpn.disconnect() : connect()
            } label: {
                Text(connectButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vpn.isConnecting || model.selectedServer == nil)
        }
        .padding(20)
    }

    private var connectButtonTitle: String {
        if vpn.isConnecting { return "Connecting…" }
        return vpn.isConnected ? "Disconnect" : "Connect"
    }

    private var serverBinding: Binding<MacVPNServer?> {
        Binding(
            get: { model.selectedServer },
            set: { model.selectServer($0) }
        )
    }

    private func connect() {
        guard let token = model.token, let server = model.selectedServer else { return }
        vpn.connect(
            tokenPayload: token,
            server: server,
            sni: model.sni,
            censorshipStrategy: model.censorshipStrategy,
            dataPlaneMode: model.dataPlaneMode,
            logLevel: model.logLevel.rawValue
        )
    }

    private func pickFastest() async {
        guard let best = await selection.selectBestServer(from: model.servers) else { return }
        model.selectServer(best)
    }
}

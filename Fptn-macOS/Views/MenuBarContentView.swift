import SwiftUI

/// Menu bar popover. Deliberately minimal: state, one action, and a way into
/// the real window. Anything that needs a decision belongs in the window.
struct MenuBarContentView: View {
    @EnvironmentObject private var model: MacAppModel
    @EnvironmentObject private var vpn: MacVPNService

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vpn.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vpn.statusText)
                        .font(.callout.weight(.medium))
                    if let server = model.selectedServer {
                        Text(server.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            if model.hasToken {
                Button(vpn.isConnected ? "Disconnect" : "Connect") {
                    guard let token = model.token, let server = model.selectedServer else { return }
                    if vpn.isConnected {
                        vpn.disconnect()
                    } else {
                        vpn.connect(
                            tokenPayload: token,
                            server: server,
                            sni: model.sni,
                            censorshipStrategy: model.censorshipStrategy
                        )
                    }
                }
                .disabled(vpn.isConnecting || model.selectedServer == nil)
            }

            Button(model.hasToken ? "Open FPTN" : "Add token…") {
                openWindow(id: MacWindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit FPTN") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 220)
    }
}

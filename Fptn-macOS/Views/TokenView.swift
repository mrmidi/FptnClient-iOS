import SwiftUI

/// First-run and sign-out state. Paste-only, matching iOS: tokens arrive from
/// @fptn_bot on another device, so free-text editing only invites typos in a
/// base64 blob no one can proofread.
struct TokenView: View {
    @EnvironmentObject private var model: MacAppModel

    @State private var pasteFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Add your access token")
                    .font(.title2.weight(.semibold))
                Text("Get a token from @fptn_bot on Telegram, copy it, then paste it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                paste()
            } label: {
                Label("Paste token", systemImage: "doc.on.clipboard")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("v", modifiers: .command)

            if let error = model.parseError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else if pasteFailed {
                Text("The clipboard is empty.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paste() {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else {
            pasteFailed = true
            model.parseError = nil
            return
        }
        pasteFailed = false
        model.applyToken(raw)
    }
}

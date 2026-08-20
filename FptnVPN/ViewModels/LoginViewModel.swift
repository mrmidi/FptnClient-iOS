/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

@MainActor
final class LoginViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var errorMessage: String? = nil
    @Published var isLoggedIn = false
    /// True when the token was loaded from iCloud rather than entered locally.
    @Published var isCloudSynced = false
    @Published private(set) var isPasting = false

    // MARK: - Dependencies

    private let tokenService: TokenService

    private nonisolated(unsafe) var cloudObserver: Any?

    init(tokenService: TokenService = .shared) {
        self.tokenService = tokenService

        isLoggedIn = tokenService.isLoggedIn()
        isCloudSynced = tokenService.wasCloudSynced()

        // Listen for iCloud KVS changes that arrive after launch.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isLoggedIn && tokenService.isLoggedIn() {
                    self.isLoggedIn = true
                    self.isCloudSynced = true
                }
            }
        }
    }

    deinit {
        if let observer = cloudObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Commands

    /// Read the clipboard, decode it, and sign in.
    ///
    /// The only way in. Tokens are hundreds of characters of base64 — nobody
    /// types one — so the screen has no text field and therefore never raises
    /// the keyboard. Everything that can go wrong is reported through
    /// `errorMessage` with advice the user can act on.
    func pasteToken() async {
        guard !isPasting else { return }
        isPasting = true
        defer { isPasting = false }

        errorMessage = nil

        do {
            let clipboard = try TokenPasteboard.readToken()
            let tokenData = try TokenDecoder.decode(clipboard)
            await tokenService.saveTokenData(tokenData)
            logger.info("Login via paste, servers: \(tokenData.servers.count)")
            isLoggedIn = true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Pasted token rejected: \(error.localizedDescription)")
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}

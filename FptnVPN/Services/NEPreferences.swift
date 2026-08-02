/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
@preconcurrency import NetworkExtension

/// The app's single entry point for `NETunnelProviderManager` preferences.
///
/// `NEConfigurationManager` is a process-wide singleton that answers every load
/// and save over one XPC connection and decodes the reply with a shared
/// `NSKeyedUnarchiver`. Nothing documents it as safe to drive from several
/// requests at once, and the app had six independent call sites doing exactly
/// that — including a save racing loads during connect/reconnect churn.
///
/// Isolation alone does not fix this. Every one of those call sites already ran
/// on the MainActor, but `loadAllFromPreferences()` suspends, which frees the
/// MainActor to start the next one; several were routinely in flight together.
/// An actor would behave identically, because actor methods are reentrant
/// across `await`. So operations chain onto their predecessor instead.
@MainActor
enum NEPreferences {
    /// Tail of the operation chain. Each new operation awaits this before
    /// touching NetworkExtension, then becomes the tail itself.
    private static var tail: Task<Void, Never>?

    /// Every manager currently saved in preferences.
    static func loadAll() async throws -> [NETunnelProviderManager] {
        try await serialized {
            try await NETunnelProviderManager.loadAllFromPreferences()
        }
    }

    /// The app's tunnel manager, or `nil` if none has been saved yet.
    static func loadFirst() async throws -> NETunnelProviderManager? {
        try await loadAll().first
    }

    /// Loads the saved manager (creating one on first use), hands it to
    /// `configure`, then saves and reloads it as a single unit — so no other
    /// caller can observe a half-written configuration.
    @discardableResult
    static func saveConfiguration(
        _ configure: @MainActor @escaping (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        try await serialized {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = existing.first ?? NETunnelProviderManager()
            configure(manager)
            try await manager.saveToPreferences()
            // Re-read so the manager reflects what the daemon actually stored
            // before anything acts on it.
            try await manager.loadFromPreferences()
            return manager
        }
    }

    /// Runs `operation` once every previously enqueued operation has finished.
    ///
    /// Operations must not nest: one that called back into `NEPreferences`
    /// would wait on a chain it is itself part of, and deadlock. That is why
    /// the methods above are the only entry points, and why each performs its
    /// whole NetworkExtension sequence inline.
    ///
    /// The result travels through a box rather than the task's own value
    /// because `NETunnelProviderManager` is not `Sendable`; everything here is
    /// MainActor-isolated, so it never leaves its isolation domain.
    private static func serialized<T>(
        _ operation: @MainActor @escaping () async throws -> T
    ) async throws -> T {
        let previous = tail
        let box = ResultBox<T>()
        let operationTask = Task { @MainActor in
            await previous?.value
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
        }
        tail = operationTask
        await operationTask.value

        guard let result = box.result else {
            throw CancellationError()
        }
        return try result.get()
    }
}

@MainActor
private final class ResultBox<T> {
    var result: Result<T, Error>?
}

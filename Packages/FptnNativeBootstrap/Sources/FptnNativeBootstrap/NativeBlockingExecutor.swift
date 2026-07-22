/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

/// Runs the synchronous native bridge on a bounded pool instead of a Swift
/// cooperative executor. Cancellation is forwarded separately to the client.
public actor NativeBlockingExecutor {
    private let queue: OperationQueue

    public init(maxConcurrent: Int = 4) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, maxConcurrent)
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

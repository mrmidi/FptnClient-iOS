/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

public protocol BlockingNativeExecuting: Sendable {
    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T
}

public actor BlockingNativeExecutor: BlockingNativeExecuting {
    private let queue: OperationQueue

    public init(maxConcurrent: Int = 4) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, maxConcurrent)
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let op = BlockOperation {
                do {
                    let result = try operation()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            self.queue.addOperation(op)
        }
    }
}

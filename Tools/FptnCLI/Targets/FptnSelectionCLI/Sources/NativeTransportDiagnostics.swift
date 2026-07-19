/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore

public struct DiagnosticResult: Sendable {
    public let reachable: Bool
    public let latencyMs: Int
    public let error: String?

    public init(reachable: Bool, latencyMs: Int, error: String? = nil) {
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.error = error
    }
}

public protocol ServerDiagnosticProbing: Sendable {
    func probe(server: VPNServer, context: BootstrapContext, timeout: Duration) async -> DiagnosticResult
}

public final class NativeTransportDiagnostics: ServerDiagnosticProbing, @unchecked Sendable {
    private let executor: BlockingNativeExecutor

    public init(executor: BlockingNativeExecutor = BlockingNativeExecutor()) {
        self.executor = executor
    }

    public func probe(
        server: VPNServer,
        context: BootstrapContext,
        timeout: Duration
    ) async -> DiagnosticResult {
        let timeoutSeconds = Int32(timeout.components.seconds)
        let client = SwiftApiClient(
            std.string(server.host),
            Int32(server.port),
            std.string(context.sni),
            std.string(server.md5Fingerprint),
            std.string(context.censorshipStrategy.rawValue)
        )
        let start = Date()
        let result = try! await executor.run {
            client.testHandshake(timeoutSeconds)
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return DiagnosticResult(
            reachable: result.reachable,
            latencyMs: elapsed,
            error: result.reachable ? nil : "handshake failed"
        )
    }
}

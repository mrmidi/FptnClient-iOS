/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnNativeBootstrap

public final class MacNativeBootstrapClient: NativeBootstrapClient, @unchecked Sendable {
    private let client: SwiftApiClient
    private let executor: BlockingNativeExecutor

    public init(server: VPNServer, context: BootstrapContext, executor: BlockingNativeExecutor = BlockingNativeExecutor()) {
        self.executor = executor
        self.client = SwiftApiClient(
            std.string(server.host),
            Int32(server.port),
            std.string(context.sni),
            std.string(server.md5Fingerprint),
            std.string(context.censorshipStrategy.rawValue)
        )
    }

    public func post(path: String, body: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        let resp = try! await executor.run {
            self.client.post(std.string(path), std.string(body), timeoutSeconds)
        }
        return NativeHTTPResponse(
            code: Int(resp.code),
            body: String(resp.body),
            errmsg: resp.errmsg.empty() ? "" : String(resp.errmsg)
        )
    }

    public func get(path: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        let resp = try! await executor.run {
            self.client.get(std.string(path), timeoutSeconds)
        }
        return NativeHTTPResponse(
            code: Int(resp.code),
            body: String(resp.body),
            errmsg: resp.errmsg.empty() ? "" : String(resp.errmsg)
        )
    }

    public func cancel() {
        // Idempotent client cancel operation
    }
}

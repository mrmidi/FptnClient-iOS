/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnNativeBootstrap

final class iOSNativeBootstrapClient: NativeBootstrapClient, @unchecked Sendable {
    private let apiClient: ApiClientBridge
    private let executor: NativeBlockingExecutor

    init(server: FptnSharedCore.VPNServer, context: BootstrapContext) {
        self.executor = NativeBlockingExecutor()
        self.apiClient = ApiClientBridge(
            host: server.host,
            port: server.port,
            sni: context.sni,
            md5Fingerprint: server.md5Fingerprint,
            censorshipStrategy: context.censorshipStrategy.rawValue,
            name: server.name
        )
    }

    func post(path: String, body: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        guard let resp = try? await executor.run({ [apiClient] in
            apiClient.post(path: path, body: body, timeout: Int(timeoutSeconds))
        }) else {
            return NativeHTTPResponse(code: -1, body: "", errmsg: "Native POST executor failed")
        }
        return NativeHTTPResponse(
            code: resp.code,
            body: resp.body ?? "",
            errmsg: resp.error ?? ""
        )
    }

    func get(path: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        guard let resp = try? await executor.run({ [apiClient] in
            apiClient.get(path: path, timeout: Int(timeoutSeconds))
        }) else {
            return NativeHTTPResponse(code: -1, body: "", errmsg: "Native GET executor failed")
        }
        return NativeHTTPResponse(
            code: resp.code,
            body: resp.body ?? "",
            errmsg: resp.error ?? ""
        )
    }

    func cancel() {
        apiClient.cancel()
    }
}

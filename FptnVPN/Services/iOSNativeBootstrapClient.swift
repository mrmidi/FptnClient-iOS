/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnNativeBootstrap

final class iOSNativeBootstrapClient: NativeBootstrapClient, @unchecked Sendable {
    private let apiClient: ApiClientBridge

    init(server: FptnSharedCore.VPNServer, context: BootstrapContext) {
        self.apiClient = ApiClientBridge(
            host: server.host,
            port: server.port,
            sni: context.sni,
            md5Fingerprint: server.md5Fingerprint,
            censorshipStrategy: context.censorshipStrategy.rawValue
        )
    }

    func post(path: String, body: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        let resp = apiClient.post(path: path, body: body, timeout: Int(timeoutSeconds))
        return NativeHTTPResponse(
            code: resp.code,
            body: resp.body ?? "",
            errmsg: resp.error ?? ""
        )
    }

    func get(path: String, timeoutSeconds: Int32) async -> NativeHTTPResponse {
        let resp = apiClient.get(path: path, timeout: Int(timeoutSeconds))
        return NativeHTTPResponse(
            code: resp.code,
            body: resp.body ?? "",
            errmsg: resp.error ?? ""
        )
    }

    func cancel() {
        // Idempotent cancel
    }
}

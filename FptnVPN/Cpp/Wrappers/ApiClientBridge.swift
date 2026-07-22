/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

struct ApiClientResponse: Sendable {
    let code: Int
    let body: String?
    let error: String?
}

struct ApiClientHandshakeResult: Sendable {
    let reachable: Bool
    let latencyMs: Int?
    let error: String?
}

final class ApiClientBridge: @unchecked Sendable {
    private let client: SwiftApiClient

    init(host: String, port: Int, sni: String, md5Fingerprint: String, censorshipStrategy: String = "SNI", name: String = "") {
        client = SwiftApiClient(
            std.string(host),
            Int32(port),
            std.string(sni),
            std.string(md5Fingerprint),
            std.string(censorshipStrategy),
            std.string(name)
        )
    }

    func get(path: String, timeout: Int) -> ApiClientResponse {
        let response = client.get(std.string(path), Int32(timeout))
        return ApiClientResponse(
            code: Int(response.code),
            body: String(response.body),
            error: response.errmsg.empty() ? nil : String(response.errmsg)
        )
    }

    func post(path: String, body: String, timeout: Int) -> ApiClientResponse {
        let response = client.post(std.string(path), std.string(body), Int32(timeout))
        return ApiClientResponse(
            code: Int(response.code),
            body: String(response.body),
            error: response.errmsg.empty() ? nil : String(response.errmsg)
        )
    }

    func testHandshake(timeout: Int) -> ApiClientHandshakeResult {
        let result = client.testHandshake(Int32(timeout))
        return ApiClientHandshakeResult(
            reachable: result.reachable,
            latencyMs: result.latency_ms >= 0 ? Int(result.latency_ms) : nil,
            error: result.errmsg.empty() ? nil : String(result.errmsg)
        )
    }

    func cancel() {
        client.cancel()
    }
}

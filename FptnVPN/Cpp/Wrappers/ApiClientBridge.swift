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
    private let client: UnsafeMutableRawPointer?

    init(host: String, port: Int, sni: String, md5Fingerprint: String, censorshipStrategy: String = "SNI") {
        client = apiClientCreate(host, Int32(port), sni, md5Fingerprint, censorshipStrategy)
    }

    func get(path: String, timeout: Int) -> ApiClientResponse {
        guard let client = client else {
            return ApiClientResponse(code: 0, body: nil, error: "Invalid handle")
        }
        
        let response = apiClientGet(client, path, Int32(timeout))
        defer { apiClientResponseFree(response) }
        return Self.convert(response)
    }

    func post(path: String, body: String, timeout: Int) -> ApiClientResponse {
        guard let client = client else {
            return ApiClientResponse(code: 0, body: nil, error: "Invalid handle")
        }
        
        let response = apiClientPost(client, path, body, Int32(timeout))
        defer { apiClientResponseFree(response) }
        return Self.convert(response)
    }

    func testHandshake(timeout: Int) -> ApiClientHandshakeResult {
        guard let client = client else {
            return ApiClientHandshakeResult(reachable: false, latencyMs: nil, error: "Invalid handle")
        }

        let response = apiClientTestHandshake(client, Int32(timeout))
        defer { apiClientHandshakeResultFree(response) }
        return ApiClientHandshakeResult(
            reachable: response.reachable,
            latencyMs: response.latency_ms >= 0 ? Int(response.latency_ms) : nil,
            error: response.errmsg.map { String(cString: $0) }
        )
    }

    private static func convert(_ response: CApiClientResponse) -> ApiClientResponse {
        ApiClientResponse(
            code: Int(response.code),
            body: response.body.map { String(cString: $0) },
            error: response.errmsg.map { String(cString: $0) }
        )
    }

    deinit {
        if let client = client {
            apiClientDestroy(client)
        }
    }
}

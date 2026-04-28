import Foundation

struct TvApiClientResponse: Sendable {
    let code: Int
    let body: String?
    let error: String?
}

struct TvApiClientHandshakeResult: Sendable {
    let reachable: Bool
    let latencyMs: Int?
    let error: String?
}

final class TvApiClientBridge: @unchecked Sendable {
    private nonisolated(unsafe) let client: UnsafeMutableRawPointer?

    init(host: String, port: Int, sni: String, md5Fingerprint: String, censorshipStrategy: String = "SNI") {
        client = apiClientCreate(host, Int32(port), sni, md5Fingerprint, censorshipStrategy)
    }

    func get(path: String, timeout: Int) -> TvApiClientResponse {
        guard let client else {
            return TvApiClientResponse(code: 0, body: nil, error: "Invalid handle")
        }

        let response = apiClientGet(client, path, Int32(timeout))
        defer { apiClientResponseFree(response) }

        return Self.convert(response)
    }

    func post(path: String, body: String, timeout: Int) -> TvApiClientResponse {
        guard let client else {
            return TvApiClientResponse(code: 0, body: nil, error: "Invalid handle")
        }

        let response = apiClientPost(client, path, body, Int32(timeout))
        defer { apiClientResponseFree(response) }

        return Self.convert(response)
    }

    func testHandshake(timeout: Int) -> TvApiClientHandshakeResult {
        guard let client else {
            return TvApiClientHandshakeResult(reachable: false, latencyMs: nil, error: "Invalid handle")
        }

        let response = apiClientTestHandshake(client, Int32(timeout))
        defer { apiClientHandshakeResultFree(response) }

        return TvApiClientHandshakeResult(
            reachable: response.reachable,
            latencyMs: response.latency_ms >= 0 ? Int(response.latency_ms) : nil,
            error: response.errmsg.map { String(cString: $0) }
        )
    }

    private static func convert(_ response: CApiClientResponse) -> TvApiClientResponse {
        TvApiClientResponse(
            code: Int(response.code),
            body: response.body.map { String(cString: $0) },
            error: response.errmsg.map { String(cString: $0) }
        )
    }

    deinit {
        if let client {
            apiClientDestroy(client)
        }
    }
}

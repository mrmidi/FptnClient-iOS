import Foundation

struct MacApiClientResponse: Sendable {
    let code: Int
    let body: String?
    let error: String?
}

struct MacApiClientHandshakeResult: Sendable {
    let reachable: Bool
    let latencyMs: Int?
    let error: String?
}

final class MacApiClientBridge: @unchecked Sendable {
    private nonisolated(unsafe) let client: SwiftApiClient

    init(host: String, port: Int, sni: String, md5Fingerprint: String, censorshipStrategy: String = "SNI") {
        client = SwiftApiClient(
            std.string(host),
            Int32(port),
            std.string(sni),
            std.string(md5Fingerprint),
            std.string(censorshipStrategy)
        )
    }

    func get(path: String, timeout: Int) -> MacApiClientResponse {
        let response = client.get(std.string(path), Int32(timeout))
        return MacApiClientResponse(
            code: Int(response.code),
            body: String(response.body),
            error: response.errmsg.empty() ? nil : String(response.errmsg)
        )
    }

    func post(path: String, body: String, timeout: Int) -> MacApiClientResponse {
        let response = client.post(std.string(path), std.string(body), Int32(timeout))
        return MacApiClientResponse(
            code: Int(response.code),
            body: String(response.body),
            error: response.errmsg.empty() ? nil : String(response.errmsg)
        )
    }

    func testHandshake(timeout: Int) -> MacApiClientHandshakeResult {
        let result = client.testHandshake(Int32(timeout))
        return MacApiClientHandshakeResult(
            reachable: result.reachable,
            latencyMs: result.latency_ms >= 0 ? Int(result.latency_ms) : nil,
            error: result.errmsg.empty() ? nil : String(result.errmsg)
        )
    }
}

/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

/// Standard struct representing the JSON login response from the FPTN server.
private struct LoginResponse: Codable {
    let access_token: String
}

/// A real native transport implementation of `ServerBootstrapProbing`.
/// Links directly to the C++ native `SwiftApiClient` via C++ Interop.
final class NativeServerBootstrapProbe: ServerBootstrapProbing, @unchecked Sendable {
    
    init() {}
    
    func probe(
        server: VPNServer,
        credentials: Credentials,
        context: ProbeContext,
        timeout: Duration,
        queuePosition: Int
    ) async -> ServerBootstrapAttempt {
        let queuedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let startedAt = queuedAt
        
        let client = SwiftApiClient(
            std.string(server.host),
            Int32(server.port),
            std.string(context.sni),
            std.string(server.md5Fingerprint),
            std.string(context.censorshipStrategy.rawValue)
        )
        
        let timeoutSeconds = Int32(timeout.components.seconds)
        
        // 1. Run the testHandshake metric (Optional diagnostic metric)
        let handshakeStart = Date()
        let handshakeResult = client.testHandshake(timeoutSeconds)
        let handshakeEnd = Date()
        let handshakeMs = Int(handshakeEnd.timeIntervalSince(handshakeStart) * 1000)
        
        // 2. Perform HTTP POST login
        let loginPayload = "{\"username\":\"\(credentials.username)\",\"password\":\"\(credentials.password)\"}"
        
        let loginStart = Date()
        let loginResponse = client.post(
            std.string("/api/v1/login"),
            std.string(loginPayload),
            timeoutSeconds
        )
        let loginEnd = Date()
        let loginMs = Int(loginEnd.timeIntervalSince(loginStart) * 1000)
        
        // Populate base metrics structure (pre-login result)
        let preMetrics = ProbeMetrics(
            serverID: server.id,
            queuePosition: queuePosition,
            queuedAtMs: queuedAt,
            startedAtMs: startedAt,
            completedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            dnsMs: nil,
            tcpConnectMs: nil,
            fakeHandshakeMs: handshakeResult.reachable ? handshakeMs : nil,
            tlsHandshakeMs: nil,
            loginHTTPMs: loginMs,
            bootstrapHTTPMs: nil,
            totalMs: Int(Int64(Date().timeIntervalSince1970 * 1000) - startedAt),
            cancellationRequestedAtMs: nil,
            cancellationCompletedAtMs: nil,
            outcome: loginResponse.code == 200 ? .success : .failure
        )
        
        guard loginResponse.code == 200 else {
            let errorMsg = loginResponse.errmsg.empty() ? nil : String(loginResponse.errmsg)
            let failKind: ServerProbeFailureKind
            
            switch loginResponse.code {
            case 401:
                failKind = .authenticationRejected
            case 403:
                failKind = .authorizationRejected
            case 429:
                failKind = .rateLimited
            case 500...599:
                failKind = .serverError
            case 608:
                failKind = .connectionTimeout
            case 601:
                failKind = .fakeHandshake
            default:
                failKind = .nativeFailure
            }
            
            return .failure(ServerProbeFailure(
                server: server,
                kind: failKind,
                metrics: preMetrics,
                safeDiagnostic: errorMsg ?? "HTTP Login Failed with code \(loginResponse.code)"
            ))
        }
        
        // Parse access_token
        let responseBody = String(loginResponse.body)
        guard let responseData = responseBody.data(using: .utf8),
              let loginObj = try? JSONDecoder().decode(LoginResponse.self, from: responseData) else {
            return .failure(ServerProbeFailure(
                server: server,
                kind: .malformedLoginResponse,
                metrics: preMetrics,
                safeDiagnostic: "Failed to parse access_token from login response."
            ))
        }
        
        // 3. Complete Bootstrap: Fetch DNS config from server (No authentication header needed for this endpoint)
        let dnsStart = Date()
        let dnsResponse = client.get(std.string("/api/v1/dns"), timeoutSeconds)
        let dnsEnd = Date()
        let dnsMs = Int(dnsEnd.timeIntervalSince(dnsStart) * 1000)
        
        let completedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let totalMs = Int(completedAt - startedAt)
        
        let finalMetrics = ProbeMetrics(
            serverID: server.id,
            queuePosition: queuePosition,
            queuedAtMs: queuedAt,
            startedAtMs: startedAt,
            completedAtMs: completedAt,
            dnsMs: nil,
            tcpConnectMs: nil,
            fakeHandshakeMs: handshakeResult.reachable ? handshakeMs : nil,
            tlsHandshakeMs: nil,
            loginHTTPMs: loginMs,
            bootstrapHTTPMs: dnsMs,
            totalMs: totalMs,
            cancellationRequestedAtMs: nil,
            cancellationCompletedAtMs: nil,
            outcome: dnsResponse.code == 200 ? .success : .failure
        )
        
        guard dnsResponse.code == 200 else {
            let errorMsg = dnsResponse.errmsg.empty() ? nil : String(dnsResponse.errmsg)
            return .failure(ServerProbeFailure(
                server: server,
                kind: .malformedBootstrapResponse,
                metrics: finalMetrics,
                safeDiagnostic: errorMsg ?? "DNS GET Failed with code \(dnsResponse.code)"
            ))
        }
        
        let dnsBody = String(dnsResponse.body)
        guard let dnsData = dnsBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: dnsData) as? [String: Any],
              let dnsIPv4 = json["dns"] as? String else {
            return .failure(ServerProbeFailure(
                server: server,
                kind: .malformedBootstrapResponse,
                metrics: finalMetrics,
                safeDiagnostic: "Failed to parse DNS values from response: \(dnsBody)"
            ))
        }
        
        let dnsIPv6 = json["dnsIPv6"] as? String
        
        return .success(ServerBootstrapResult(
            server: server,
            accessToken: loginObj.access_token,
            dnsIPv4: dnsIPv4,
            dnsIPv6: dnsIPv6,
            metrics: finalMetrics
        ))
    }
}

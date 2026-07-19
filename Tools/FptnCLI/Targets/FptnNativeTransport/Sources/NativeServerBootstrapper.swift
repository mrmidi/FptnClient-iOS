/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

private struct LoginRequest: Encodable {
    let username: String
    let password: String
}

private struct DNSResponse: Decodable {
    let dnsIPv4: String
    let dnsIPv6: String?

    enum CodingKeys: String, CodingKey {
        case dnsIPv4 = "dns"
        case dnsIPv6 = "dns_ipv6"
    }
}

public final class NativeServerBootstrapper: ServerBootstrapping, @unchecked Sendable {
    private let executor: BlockingNativeExecutor

    public init(executor: BlockingNativeExecutor = BlockingNativeExecutor()) {
        self.executor = executor
    }

    public func bootstrap(
        server: VPNServer,
        credentials: Credentials,
        context: BootstrapContext,
        attempt: BootstrapAttemptContext,
        policy: BootstrapPolicy
    ) async -> ServerBootstrapAttempt {
        let timeoutSeconds = Int32(policy.stageTimeout.components.seconds)

        let client = SwiftApiClient(
            std.string(server.host),
            Int32(server.port),
            std.string(context.sni),
            std.string(server.md5Fingerprint),
            std.string(context.censorshipStrategy.rawValue)
        )

        let loginPayload: String
        do {
            let req = LoginRequest(username: credentials.username, password: credentials.password)
            let data = try JSONEncoder().encode(req)
            loginPayload = String(data: data, encoding: .utf8) ?? ""
        } catch {
            return .failure(ServerProbeFailure(
                server: server, kind: .malformedLoginResponse,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: nil, bootstrapHTTPMs: nil,
                    totalMs: 0, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .failure),
                safeDiagnostic: "Failed to encode login payload."
            ))
        }

        let loginResponse = await executor.run {
            client.post(std.string("/api/v1/login"), std.string(loginPayload), timeoutSeconds)
        }

        let loginMs = Int(Int64(Date().timeIntervalSince1970 * 1000))

        guard loginResponse.code == 200 else {
            let errorMsg = loginResponse.errmsg.empty() ? nil : String(loginResponse.errmsg)
            let failKind = mapFailureKind(loginResponse.code)
            return .failure(ServerProbeFailure(
                server: server, kind: failKind,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: loginMs, bootstrapHTTPMs: nil,
                    totalMs: loginMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .failure),
                safeDiagnostic: errorMsg ?? "HTTP Login Failed with code \(loginResponse.code)"
            ))
        }

        let responseBody = String(loginResponse.body)
        guard let responseData = responseBody.data(using: .utf8),
              let loginObj = try? JSONDecoder().decode(DNSResponse.AccessToken.self, from: responseData) else {
            return .failure(ServerProbeFailure(
                server: server, kind: .malformedLoginResponse,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: loginMs, bootstrapHTTPMs: nil,
                    totalMs: loginMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .failure),
                safeDiagnostic: "Failed to parse access_token from login response."
            ))
        }

        let dnsResponse = await executor.run {
            client.get(std.string("/api/v1/dns"), timeoutSeconds)
        }

        guard dnsResponse.code == 200 else {
            let errorMsg = dnsResponse.errmsg.empty() ? nil : String(dnsResponse.errmsg)
            return .failure(ServerProbeFailure(
                server: server, kind: .malformedBootstrapResponse,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: loginMs, bootstrapHTTPMs: 0,
                    totalMs: loginMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .failure),
                safeDiagnostic: errorMsg ?? "DNS GET Failed with code \(dnsResponse.code)"
            ))
        }

        let dnsBody = String(dnsResponse.body)
        guard let dnsData = dnsBody.data(using: .utf8),
              let dnsObj = try? JSONDecoder().decode(DNSResponse.self, from: dnsData) else {
            return .failure(ServerProbeFailure(
                server: server, kind: .malformedBootstrapResponse,
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: loginMs, bootstrapHTTPMs: 0,
                    totalMs: loginMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .failure),
                safeDiagnostic: "Failed to parse DNS values from response."
            ))
        }

        return .success(ServerBootstrapResult(
            server: server,
            accessToken: loginObj.access_token,
            dnsIPv4: dnsObj.dnsIPv4,
            dnsIPv6: validIPv6(dnsObj.dnsIPv6),
            metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                tlsHandshakeMs: nil, loginHTTPMs: loginMs, bootstrapHTTPMs: 0,
                totalMs: loginMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                outcome: .success)
        ))
    }

    private func mapFailureKind(_ code: Int) -> ServerProbeFailureKind {
        switch code {
        case 401: return .authenticationRejected
        case 403: return .authorizationRejected
        case 429: return .rateLimited
        case 500...599: return .serverError
        case 608: return .connectionTimeout
        case 601: return .fakeHandshake
        default: return .nativeFailure
        }
    }

    private func validIPv6(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) == 1 ? value : nil }
    }
}

private extension DNSResponse {
    struct AccessToken: Decodable {
        let access_token: String
    }
}

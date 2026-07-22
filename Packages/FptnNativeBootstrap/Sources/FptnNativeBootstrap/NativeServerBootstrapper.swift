/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

public final class NativeServerBootstrapper: ServerBootstrapping, @unchecked Sendable {
    private let clientFactory: @Sendable (VPNServer, BootstrapContext) -> any NativeBootstrapClient

    public init(clientFactory: @escaping @Sendable (VPNServer, BootstrapContext) -> any NativeBootstrapClient) {
        self.clientFactory = clientFactory
    }

    public func bootstrap(
        server: VPNServer,
        credentials: Credentials,
        context: BootstrapContext,
        attempt: BootstrapAttemptContext,
        policy: BootstrapPolicy
    ) async -> ServerBootstrapAttempt {
        let client = clientFactory(server, context)

        return await withTaskCancellationHandler {
            let timeoutSeconds = Int32(policy.stageTimeout.components.seconds)
            let startTime = Date()

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

            let loginResponse = await client.post(path: "/api/v1/login", body: loginPayload, timeoutSeconds: timeoutSeconds)
            let loginElapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

            if Task.isCancelled {
                let totalElapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                let elapsed64 = Int64(totalElapsedMs)
                return .failure(ServerProbeFailure(
                    server: server, kind: .cancelled,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: nil,
                        totalMs: totalElapsedMs, cancellationRequestedAtMs: elapsed64, cancellationCompletedAtMs: elapsed64,
                        outcome: .cancelled),
                    safeDiagnostic: "Bootstrap cancelled by task group."
                ))
            }

            guard loginResponse.code == 200 else {
                let failKind = mapFailureKind(loginResponse.code)
                return .failure(ServerProbeFailure(
                    server: server, kind: failKind,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: nil,
                        totalMs: loginElapsedMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                        outcome: .failure),
                    safeDiagnostic: loginResponse.errmsg.isEmpty ? "HTTP Login Failed with code \(loginResponse.code)" : loginResponse.errmsg
                ))
            }

            guard let responseData = loginResponse.body.data(using: .utf8),
                  let loginObj = try? JSONDecoder().decode(LoginResponse.self, from: responseData) else {
                return .failure(ServerProbeFailure(
                    server: server, kind: .malformedLoginResponse,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: nil,
                        totalMs: loginElapsedMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                        outcome: .failure),
                    safeDiagnostic: "Failed to parse access_token from login response."
                ))
            }

            let dnsResponse = await client.get(path: "/api/v1/dns", timeoutSeconds: timeoutSeconds)
            let totalElapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let dnsElapsedMs = totalElapsedMs - loginElapsedMs

            if Task.isCancelled {
                let elapsed64 = Int64(totalElapsedMs)
                return .failure(ServerProbeFailure(
                    server: server, kind: .cancelled,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: dnsElapsedMs,
                        totalMs: totalElapsedMs, cancellationRequestedAtMs: elapsed64, cancellationCompletedAtMs: elapsed64,
                        outcome: .cancelled),
                    safeDiagnostic: "Bootstrap cancelled by task group."
                ))
            }

            guard dnsResponse.code == 200 else {
                return .failure(ServerProbeFailure(
                    server: server, kind: .malformedBootstrapResponse,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: dnsElapsedMs,
                        totalMs: totalElapsedMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                        outcome: .failure),
                    safeDiagnostic: dnsResponse.errmsg.isEmpty ? "DNS GET Failed with code \(dnsResponse.code)" : dnsResponse.errmsg
                ))
            }

            guard let dnsData = dnsResponse.body.data(using: .utf8),
                  let dnsObj = try? JSONDecoder().decode(DNSResponse.self, from: dnsData) else {
                return .failure(ServerProbeFailure(
                    server: server, kind: .malformedBootstrapResponse,
                    metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                        queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                        dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                        tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: dnsElapsedMs,
                        totalMs: totalElapsedMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                        outcome: .failure),
                    safeDiagnostic: "Failed to parse DNS values from response."
                ))
            }

            return .success(ServerBootstrapResult(
                server: server,
                accessToken: loginObj.accessToken,
                dnsIPv4: dnsObj.dnsIPv4,
                dnsIPv6: validIPv6(dnsObj.dnsIPv6),
                metrics: ProbeMetrics(serverID: server.id, queuePosition: attempt.queuePosition,
                    queuedAtMs: 0, startedAtMs: 0, completedAtMs: 0,
                    dnsMs: nil, tcpConnectMs: nil, fakeHandshakeMs: nil,
                    tlsHandshakeMs: nil, loginHTTPMs: loginElapsedMs, bootstrapHTTPMs: dnsElapsedMs,
                    totalMs: totalElapsedMs, cancellationRequestedAtMs: nil, cancellationCompletedAtMs: nil,
                    outcome: .success)
            ))
        } onCancel: {
            client.cancel()
        }
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

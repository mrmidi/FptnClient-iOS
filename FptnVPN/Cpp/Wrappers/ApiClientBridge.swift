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

    func cancel() {
        client.cancel()
    }

    // MARK: - Async

    // The native side runs these on its own I/O threads and calls back when
    // done, so no Swift thread is blocked and no executor hop is needed.
    // Cancelling the surrounding Task forwards to the C++ cancellation signal,
    // which is emitted on the operation's own strand.

    func get(path: String, timeout: Int) async -> ApiClientResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(
                    ContinuationBox<ApiClientResponse>(continuation)
                ).toOpaque()
                client.getAsync(std.string(path), Int32(timeout), box) { context, response in
                    guard let context else { return }
                    let box = Unmanaged<ContinuationBox<ApiClientResponse>>
                        .fromOpaque(context).takeRetainedValue()
                    box.resume(with: ApiClientResponse(
                        code: Int(response.code),
                        body: String(response.body),
                        error: response.errmsg.empty() ? nil : String(response.errmsg)
                    ))
                }
            }
        } onCancel: {
            client.cancel()
        }
    }

    func post(path: String, body: String, timeout: Int) async -> ApiClientResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(
                    ContinuationBox<ApiClientResponse>(continuation)
                ).toOpaque()
                client.postAsync(
                    std.string(path), std.string(body), Int32(timeout), box
                ) { context, response in
                    guard let context else { return }
                    let box = Unmanaged<ContinuationBox<ApiClientResponse>>
                        .fromOpaque(context).takeRetainedValue()
                    box.resume(with: ApiClientResponse(
                        code: Int(response.code),
                        body: String(response.body),
                        error: response.errmsg.empty() ? nil : String(response.errmsg)
                    ))
                }
            }
        } onCancel: {
            client.cancel()
        }
    }

    func testHandshake(timeout: Int) async -> ApiClientHandshakeResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(
                    ContinuationBox<ApiClientHandshakeResult>(continuation)
                ).toOpaque()
                client.testHandshakeAsync(Int32(timeout), box) { context, result in
                    guard let context else { return }
                    let box = Unmanaged<ContinuationBox<ApiClientHandshakeResult>>
                        .fromOpaque(context).takeRetainedValue()
                    box.resume(with: ApiClientHandshakeResult(
                        reachable: result.reachable,
                        latencyMs: result.latency_ms >= 0 ? Int(result.latency_ms) : nil,
                        error: result.errmsg.empty() ? nil : String(result.errmsg)
                    ))
                }
            }
        } onCancel: {
            client.cancel()
        }
    }
}

/// Carries a continuation across the C++ boundary as an opaque pointer.
/// `resume` is guarded because a cancelled operation and its natural
/// completion can both reach the callback.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

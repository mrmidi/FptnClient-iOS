/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

struct WebsocketClientStatus: Sendable {
    let running: Bool
    let started: Bool
    let idleTimeoutSeconds: Int
    let lastError: String?
    let lastDisconnectReason: String?
    let memoryResidentBytes: UInt64
    let memoryPhysFootprintBytes: UInt64
    let receivedPacketCount: Int64
    let receivedByteCount: Int64
    let callbackEnterCount: Int64
    let callbackExitCount: Int64
    let callbackByteCount: Int64
    let inPacketCallback: Bool
    // PR1A: socket buffer diagnostics and process-wide lifecycle counters.
    let requestedRcvbufBytes: Int
    let requestedSndbufBytes: Int
    let effectiveRcvbufBytes: Int
    let effectiveSndbufBytes: Int
    let liveClients: Int
    let activeReaderCoroutines: Int
    let activeSenderCoroutines: Int
    let socketBufferSetErrorCount: Int
    // PR1B: outbound queue diagnostics.
    let queuedPackets: UInt64
    let queuedBytes: UInt64
    let queuedBytesPeak: UInt64
    let queueFullCount: UInt64
    // PR1C: teardown diagnostics.
    let disconnectCode: WebsocketDisconnectCode
    let stopOrigin: WebsocketStopOrigin
    let stopCleanupCompleted: Bool
    let activeOperations: UInt32
}

final class WebsocketClientBridge {

    typealias PacketCallback     = (Data) -> Void
    typealias ConnectionCallback = () -> Void
    typealias DisconnectionCallback = (_ wasConnected: Bool, _ reason: String) -> Void
    typealias IPAssignedCallback = (_ ipv4: String, _ ipv6: String) -> Void

    // MARK: - Private state

    private var clientBridge: WebsocketSwiftBridge! = nil
    private let packetCallback: PacketCallback
    private let connectedCallback: ConnectionCallback
    private let disconnectedCallback: DisconnectionCallback
    private let ipAssignedCallback: IPAssignedCallback

    // MARK: - Init / deinit

    init(
        serverIP: String,
        serverPort: Int,
        tunInterfaceIPv4: String,
        sni: String,
        accessToken: String,
        md5Fingerprint: String,
        censorshipStrategy: String = "SNI",
        packetCallback: @escaping PacketCallback,
        connectedCallback: @escaping ConnectionCallback,
        disconnectedCallback: @escaping DisconnectionCallback = { _, _ in },
        ipAssignedCallback: @escaping IPAssignedCallback = { _, _ in }
    ) {
        self.packetCallback    = packetCallback
        self.connectedCallback = connectedCallback
        self.disconnectedCallback = disconnectedCallback
        self.ipAssignedCallback = ipAssignedCallback

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        self.clientBridge = WebsocketSwiftBridge(
            std.string(serverIP),
            Int32(serverPort),
            std.string(tunInterfaceIPv4),
            std.string(sni),
            std.string(accessToken),
            std.string(md5Fingerprint),
            std.string(censorshipStrategy),
            // IPPacketCallback
            { rawPtr, length, ctx in
                guard let ctx, let rawPtr else { return }
                let bridge = Unmanaged<WebsocketClientBridge>
                    .fromOpaque(ctx).takeUnretainedValue()
                bridge.packetCallback(Data(bytes: rawPtr, count: Int(length)))
            },
            // ConnectionCallback
            { ctx in
                guard let ctx else { return }
                Unmanaged<WebsocketClientBridge>
                    .fromOpaque(ctx).takeUnretainedValue()
                    .connectedCallback()
            },
            // DisconnectedCallback
            { wasConnected, reason, ctx in
                guard let ctx else { return }
                let bridge = Unmanaged<WebsocketClientBridge>
                    .fromOpaque(ctx).takeUnretainedValue()
                let message = reason.map { String(cString: $0) } ?? "connection_closed"
                bridge.disconnectedCallback(wasConnected, message)
            },
            ctx
        )

        self.clientBridge.registerIPAssignedCallback { ipv4Ptr, ipv6Ptr, ctx in
            guard let ctx, let ipv4Ptr, let ipv6Ptr else { return }
            let bridge = Unmanaged<WebsocketClientBridge>
                .fromOpaque(ctx).takeUnretainedValue()
            let ipv4 = String(cString: ipv4Ptr)
            let ipv6 = String(cString: ipv6Ptr)
            bridge.ipAssignedCallback(ipv4, ipv6)
        }

        logger.trace("WebsocketClientBridge created — \(serverIP):\(serverPort)")
    }

    // MARK: - Control

    @discardableResult
    func start() -> Bool {
        let ok = clientBridge.start()
        logger.debug("WebSocket start → \(ok)")
        return ok
    }

    // PR1C: stop accepts an origin for disconnect classification.
    @discardableResult
    func stop(origin: WebsocketStopOrigin = .swiftTunnelStop) -> Bool {
        let ok = clientBridge.stop(origin.rawValue)
        logger.debug("WebSocket stop → \(ok) origin=\(origin)")
        return ok
    }

    // PR1B: returns typed send result for provider-level diagnostics.
    func sendPacket(_ data: Data) -> WebsocketSendResult {
        guard !data.isEmpty else {
            return .invalidPacket
        }
        let rawValue: UInt8 = data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress?
                .assumingMemoryBound(to: UInt8.self) else {
                return WebsocketSendResult.invalidPacket.rawValue
            }
            return clientBridge.sendPacket(pointer, UInt32(data.count))
        }
        return WebsocketSendResult(bridgeValue: rawValue)
    }

    var isStarted: Bool {
        clientBridge.isStarted()
    }

    var status: WebsocketClientStatus {
        let raw = clientBridge.getStatus()
        return WebsocketClientStatus(
            running: raw.running,
            started: raw.started,
            idleTimeoutSeconds: Int(raw.idle_timeout_seconds),
            lastError: raw.last_error.empty() ? nil : String(raw.last_error),
            lastDisconnectReason: raw.last_disconnect_reason.empty() ? nil : String(raw.last_disconnect_reason),
            memoryResidentBytes: raw.memory_resident_bytes,
            memoryPhysFootprintBytes: raw.memory_phys_footprint_bytes,
            receivedPacketCount: Int64(raw.received_packet_count),
            receivedByteCount: Int64(raw.received_byte_count),
            callbackEnterCount: Int64(raw.callback_enter_count),
            callbackExitCount: Int64(raw.callback_exit_count),
            callbackByteCount: Int64(raw.callback_byte_count),
            inPacketCallback: raw.in_packet_callback,
            requestedRcvbufBytes: Int(raw.requested_rcvbuf_bytes),
            requestedSndbufBytes: Int(raw.requested_sndbuf_bytes),
            effectiveRcvbufBytes: Int(raw.effective_rcvbuf_bytes),
            effectiveSndbufBytes: Int(raw.effective_sndbuf_bytes),
            liveClients: Int(raw.live_clients),
            activeReaderCoroutines: Int(raw.active_reader_coroutines),
            activeSenderCoroutines: Int(raw.active_sender_coroutines),
            socketBufferSetErrorCount: Int(raw.socket_buffer_set_error_count),
            queuedPackets: raw.queued_packets,
            queuedBytes: raw.queued_bytes,
            queuedBytesPeak: raw.queued_bytes_peak,
            queueFullCount: raw.queue_full_count,
            disconnectCode: WebsocketDisconnectCode(bridgeValue: raw.disconnect_code),
            stopOrigin: WebsocketStopOrigin(bridgeValue: raw.stop_origin),
            stopCleanupCompleted: raw.stop_cleanup_completed,
            activeOperations: raw.active_operations
        )
    }
}

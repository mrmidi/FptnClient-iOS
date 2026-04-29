/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

// Phase 2: Single-layer Swift → C bridge. The ObjC++ NativeWebsocketClientBridge
// class and both .mm files have been removed. Callbacks are now wired correctly.

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
}

final class WebsocketClientBridge {

    typealias PacketCallback     = (Data) -> Void
    typealias ConnectionCallback = () -> Void
    typealias DisconnectionCallback = (_ wasConnected: Bool, _ reason: String) -> Void

    // MARK: - Private state

    private var handle: WebsocketClientBridgePtr?
    private let packetCallback: PacketCallback
    private let connectedCallback: ConnectionCallback
    private let disconnectedCallback: DisconnectionCallback

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
        disconnectedCallback: @escaping DisconnectionCallback = { _, _ in }
    ) {
        self.packetCallback    = packetCallback
        self.connectedCallback = connectedCallback
        self.disconnectedCallback = disconnectedCallback
        self.handle            = nil   // all stored properties now initialised

        // passUnretained is correct here: VPNService (the owner) already holds
        // a strong reference to this object, so the raw pointer stays valid for
        // the lifetime of the C client. No retain cycle, no manual release needed.
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        handle = websocket_client_bridge_create(
            serverIP,
            Int32(serverPort),
            tunInterfaceIPv4,
            sni,
            accessToken,
            md5Fingerprint,
            censorshipStrategy,
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

        logger.trace("WebsocketClientBridge created — \(serverIP):\(serverPort)")
    }

    deinit {
        if let handle {
            websocket_client_bridge_destroy(handle)
        }
    }

    // MARK: - Control

    @discardableResult
    func start() -> Bool {
        guard let handle else { return false }
        let ok = websocket_client_bridge_start(handle)
        logger.debug("WebSocket start → \(ok)")
        return ok
    }

    @discardableResult
    func stop() -> Bool {
        guard let handle else { return false }
        let ok = websocket_client_bridge_stop(handle)
        logger.debug("WebSocket stop → \(ok)")
        return ok
    }

    @discardableResult
    func sendPacket(_ data: Data) -> Bool {
        guard let handle else { return false }
        return data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return websocket_client_bridge_send_packet(handle, ptr, UInt32(data.count))
        }
    }

    var isStarted: Bool {
        handle.map { websocket_client_bridge_is_started($0) } ?? false
    }

    var status: WebsocketClientStatus {
        guard let handle else {
            return WebsocketClientStatus(
                running: false,
                started: false,
                idleTimeoutSeconds: 0,
                lastError: "Invalid handle",
                lastDisconnectReason: nil,
                memoryResidentBytes: 0,
                memoryPhysFootprintBytes: 0,
                receivedPacketCount: 0,
                receivedByteCount: 0,
                callbackEnterCount: 0,
                callbackExitCount: 0,
                callbackByteCount: 0,
                inPacketCallback: false
            )
        }

        let raw = websocket_client_bridge_status(handle)
        defer { websocket_client_bridge_status_free(raw) }
        return WebsocketClientStatus(
            running: raw.running,
            started: raw.started,
            idleTimeoutSeconds: Int(raw.idle_timeout_seconds),
            lastError: raw.last_error.map { String(cString: $0) },
            lastDisconnectReason: raw.last_disconnect_reason.map { String(cString: $0) },
            memoryResidentBytes: raw.memory_resident_bytes,
            memoryPhysFootprintBytes: raw.memory_phys_footprint_bytes,
            receivedPacketCount: Int64(raw.received_packet_count),
            receivedByteCount: Int64(raw.received_byte_count),
            callbackEnterCount: Int64(raw.callback_enter_count),
            callbackExitCount: Int64(raw.callback_exit_count),
            callbackByteCount: Int64(raw.callback_byte_count),
            inPacketCallback: raw.in_packet_callback
        )
    }
}

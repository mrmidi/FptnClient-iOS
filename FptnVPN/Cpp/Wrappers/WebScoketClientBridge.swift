/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

// Phase 2: Single-layer Swift → C bridge. The ObjC++ NativeWebsocketClientBridge
// class and both .mm files have been removed. Callbacks are now wired correctly.

import Foundation

final class WebsocketClientBridge {

    typealias PacketCallback     = (Data) -> Void
    typealias ConnectionCallback = () -> Void

    // MARK: - Private state

    private var handle: WebsocketClientBridgePtr?
    private let packetCallback: PacketCallback
    private let connectedCallback: ConnectionCallback

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
        connectedCallback: @escaping ConnectionCallback
    ) {
        self.packetCallback    = packetCallback
        self.connectedCallback = connectedCallback
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
}

import Foundation
import OSLog

final class WebsocketClientBridge {
    typealias PacketCallback = (Data) -> Void
    typealias ConnectionCallback = () -> Void
    typealias DisconnectionCallback = (_ wasConnected: Bool, _ reason: String) -> Void
    typealias IPAssignedCallback = (_ ipv4: String, _ ipv6: String) -> Void

    private static let log = Logger(subsystem: "net.mrmidi.Fptn-macOS", category: "WebsocketBridge")

    private var handle: WebsocketClientBridgePtr?
    private let packetCallback: PacketCallback
    private let connectedCallback: ConnectionCallback
    private let disconnectedCallback: DisconnectionCallback
    private let ipAssignedCallback: IPAssignedCallback

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
        self.packetCallback = packetCallback
        self.connectedCallback = connectedCallback
        self.disconnectedCallback = disconnectedCallback
        self.ipAssignedCallback = ipAssignedCallback
        self.handle = nil

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = websocket_client_bridge_create(
            serverIP,
            Int32(serverPort),
            tunInterfaceIPv4,
            sni,
            accessToken,
            md5Fingerprint,
            censorshipStrategy,
            { rawPtr, length, ctx in
                guard let ctx, let rawPtr else { return }
                let bridge = Unmanaged<WebsocketClientBridge>.fromOpaque(ctx).takeUnretainedValue()
                bridge.packetCallback(Data(bytes: rawPtr, count: Int(length)))
            },
            { ctx in
                guard let ctx else { return }
                let bridge = Unmanaged<WebsocketClientBridge>.fromOpaque(ctx).takeUnretainedValue()
                bridge.connectedCallback()
            },
            { wasConnected, reason, ctx in
                guard let ctx else { return }
                let bridge = Unmanaged<WebsocketClientBridge>.fromOpaque(ctx).takeUnretainedValue()
                let message = reason.map { String(cString: $0) } ?? "connection_closed"
                bridge.disconnectedCallback(wasConnected, message)
            },
            ctx
        )

        if let handle {
            websocket_client_bridge_register_ip_assigned_callback(
                handle,
                { ipv4Ptr, ipv6Ptr, ctx in
                    guard let ctx, let ipv4Ptr, let ipv6Ptr else { return }
                    let bridge = Unmanaged<WebsocketClientBridge>
                        .fromOpaque(ctx).takeUnretainedValue()
                    let ipv4 = String(cString: ipv4Ptr)
                    let ipv6 = String(cString: ipv6Ptr)
                    bridge.ipAssignedCallback(ipv4, ipv6)
                }
            )
        }

        Self.log.debug("Bridge created for \(serverIP, privacy: .public):\(serverPort, privacy: .public)")
    }

    deinit {
        if let handle {
            websocket_client_bridge_destroy(handle)
        }
    }

    @discardableResult
    func start() -> Bool {
        guard let handle else { return false }
        let started = websocket_client_bridge_start(handle)
        Self.log.debug("Bridge start -> \(started, privacy: .public)")
        return started
    }

    @discardableResult
    func stop() -> Bool {
        guard let handle else { return false }
        let stopped = websocket_client_bridge_stop(handle)
        Self.log.debug("Bridge stop -> \(stopped, privacy: .public)")
        return stopped
    }

    @discardableResult
    func sendPacket(_ data: Data) -> Bool {
        guard let handle else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return websocket_client_bridge_send_packet(handle, base, UInt32(data.count))
        }
    }

    var isStarted: Bool {
        guard let handle else { return false }
        return websocket_client_bridge_is_started(handle)
    }
}

extension WebsocketClientBridge: TunnelWebSocketTransport {}

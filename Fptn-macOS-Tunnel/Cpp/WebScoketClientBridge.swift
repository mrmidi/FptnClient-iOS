import Foundation
import OSLog

final class WebsocketClientBridge {
    typealias PacketCallback = (Data) -> Void
    typealias ConnectionCallback = () -> Void

    private static let log = Logger(subsystem: "net.mrmidi.Fptn-macOS", category: "WebsocketBridge")

    private var handle: WebsocketClientBridgePtr?
    private let packetCallback: PacketCallback
    private let connectedCallback: ConnectionCallback

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
        self.packetCallback = packetCallback
        self.connectedCallback = connectedCallback
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
            ctx
        )

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

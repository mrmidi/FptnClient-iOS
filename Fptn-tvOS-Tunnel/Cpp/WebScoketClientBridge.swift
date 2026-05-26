import Foundation
import OSLog

final class WebsocketClientBridge {
    typealias PacketCallback = (Data) -> Void
    typealias ConnectionCallback = () -> Void
    typealias DisconnectionCallback = (_ wasConnected: Bool, _ reason: String) -> Void
    typealias IPAssignedCallback = (_ ipv4: String, _ ipv6: String) -> Void

    private static let log = Logger(subsystem: "net.mrmidi.Fptn-tvOS", category: "WebsocketBridge")

    private var clientBridge: WebsocketSwiftBridge! = nil
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

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        self.clientBridge = WebsocketSwiftBridge(
            std.string(serverIP),
            Int32(serverPort),
            std.string(tunInterfaceIPv4),
            std.string(sni),
            std.string(accessToken),
            std.string(md5Fingerprint),
            std.string(censorshipStrategy),
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

        self.clientBridge.registerIPAssignedCallback { ipv4Ptr, ipv6Ptr, ctx in
            guard let ctx, let ipv4Ptr, let ipv6Ptr else { return }
            let bridge = Unmanaged<WebsocketClientBridge>
                .fromOpaque(ctx).takeUnretainedValue()
            let ipv4 = String(cString: ipv4Ptr)
            let ipv6 = String(cString: ipv6Ptr)
            bridge.ipAssignedCallback(ipv4, ipv6)
        }

        Self.log.debug("Bridge created for \(serverIP, privacy: .public):\(serverPort, privacy: .public)")
    }

    @discardableResult
    func start() -> Bool {
        let started = clientBridge.start()
        Self.log.debug("Bridge start -> \(started, privacy: .public)")
        return started
    }

    @discardableResult
    func stop() -> Bool {
        let stopped = clientBridge.stop()
        Self.log.debug("Bridge stop -> \(stopped, privacy: .public)")
        return stopped
    }

    @discardableResult
    func sendPacket(_ data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return clientBridge.sendPacket(base, UInt32(data.count))
        }
    }

    var isStarted: Bool {
        clientBridge.isStarted()
    }
}

import Foundation
import NetworkExtension
import OSLog
import FptnSharedCore
import FptnSharedTunnel

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let log = Logger(subsystem: "net.mrmidi.Fptn-tvOS", category: "PacketTunnel")

    private let stateQueue = DispatchQueue(label: "net.mrmidi.Fptn-tvOS.tunnel.state")
    private var wsClient: WebsocketClientBridge?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var didCompleteStart = false
    private var assignedIPv4: String?
    private var assignedIPv6: String?
    private var appliedIPv4: String?
    private var appliedIPv6: String?

    private var isRunning = false
    private var runtimeLogLevel: SharedLogLevel = .warning

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = config.providerConfiguration,
              let startupData = providerConfig[TunnelProviderConfigurationKey.startupV1] as? Data,
              startupData.count <= TunnelStartupConfigurationV1.maximumEncodedSize,
              let payload = try? JSONDecoder().decode(TunnelStartupConfigurationV1.self, from: startupData) else {
            completionHandler(makeError("Missing or invalid providerConfiguration"))
            return
        }

        runtimeLogLevel = payload.logLevel
        isRunning = false

        stateQueue.sync {
            startCompletion = completionHandler
            didCompleteStart = false
            assignedIPv4 = nil
            assignedIPv6 = nil
            appliedIPv4 = nil
            appliedIPv6 = nil
        }

        log.log("startTunnel server=\(payload.serverHost, privacy: .public):\(payload.serverPort, privacy: .public) sni=\(payload.sni, privacy: .public) level=\(self.runtimeLogLevel.rawValue, privacy: .public)")

        let tunIPv4 = "10.8.0.2"
        let tunIPv4Gateway = "10.8.0.1"

        scheduleStartTimeout(seconds: 15)

        wsClient = WebsocketClientBridge(
            serverIP: payload.serverHost,
            serverPort: payload.serverPort,
            tunInterfaceIPv4: tunIPv4,
            sni: payload.sni,
            accessToken: payload.accessToken,
            md5Fingerprint: payload.md5Fingerprint,
            packetCallback: { [weak self] packet in
                self?.handleIncomingPacketFromServer(packet)
            },
            connectedCallback: { [weak self] in
                self?.log.log("WebSocket connected; applying packet tunnel settings")
                guard let self else { return }
                var cIPv4: String?
                var cIPv6: String?
                var alreadyApplied = false
                var ipChanged = false
                self.stateQueue.sync {
                    cIPv4 = self.assignedIPv4
                    cIPv6 = self.assignedIPv6
                    alreadyApplied = self.isRunning
                    ipChanged = (self.assignedIPv4 != self.appliedIPv4) || (self.assignedIPv6 != self.appliedIPv6)
                }
                
                let shouldApply = !alreadyApplied || ipChanged
                if shouldApply {
                    self.applyNetworkSettings(
                        serverIP: payload.serverHost,
                        tunIPv4: tunIPv4,
                        tunIPv4Gateway: tunIPv4Gateway,
                        dnsIPv4: payload.dnsIPv4,
                        dnsIPv6: payload.dnsIPv6,
                        assignedIPv4: cIPv4,
                        assignedIPv6: cIPv6
                    ) { error in
                        if let error {
                            self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                            self.finishStart(with: error)
                            return
                        }
                        self.stateQueue.sync {
                            self.appliedIPv4 = cIPv4
                            self.appliedIPv6 = cIPv6
                        }
                        self.isRunning = true
                        self.startReadLoop()
                        self.finishStart(with: nil)
                    }
                } else {
                    self.isRunning = true
                    self.startReadLoop()
                    self.finishStart(with: nil)
                }
            },
            ipAssignedCallback: { [weak self] ipv4, ipv6 in
                guard let self else { return }
                self.stateQueue.sync {
                    self.assignedIPv4 = ipv4
                    self.assignedIPv6 = ipv6
                }
                self.log.info("IP assignment received from bridge: IPv4=\(ipv4, privacy: .public), IPv6=\(ipv6, privacy: .public)")
            }
        )

        guard wsClient?.start() == true else {
            finishStart(with: makeError("WebSocket start failed"))
            return
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        invalidateStartTimeout()
        finishStart(with: makeError("Tunnel stopped before startup completed"))
        _ = wsClient?.stop()
        wsClient = nil
        log.log("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONDecoder().decode(TunnelControlMessage.self, from: messageData) else {
            completionHandler?(encodeResponse(.init(ok: false, message: "invalid_payload")))
            return
        }

        switch message.action {
        case .ping:
            completionHandler?(encodeResponse(.init(ok: true, message: "pong")))
        case .getStatus:
            let status = isRunning ? (wsClient?.isStarted == true ? "running" : "starting") : "stopped"
            completionHandler?(encodeResponse(.init(ok: true, message: status)))
        case .setLogLevel:
            runtimeLogLevel = message.logLevel ?? .warning
            completionHandler?(encodeResponse(.init(ok: true, message: "log_level_updated")))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log.debug("sleep")
        completionHandler()
    }

    override func wake() {
        log.debug("wake")
    }

    private func applyNetworkSettings(
        tunIPv4: String,
        tunIPv4Gateway: String,
        dnsIPv4: String,
        dnsIPv6: String,
        assignedIPv4: String?,
        assignedIPv6: String?,
        completion: @escaping (Error?) -> Void
    ) {
        let clientIPv4 = assignedIPv4 ?? tunIPv4
        let gatewayIPv4 = assignedIPv4 != nil ? dnsIPv4 : tunIPv4Gateway
        let clientIPv6 = assignedIPv6 ?? "fd00::1"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gatewayIPv4)

        let ipv4 = NEIPv4Settings(addresses: [clientIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        var servers = [dnsIPv4]
        let hasDnsIPv6 = !dnsIPv6.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dnsIPv6.contains(":")
        if hasDnsIPv6 {
            servers.append(dnsIPv6)
        }

        let dns = NEDNSSettings(servers: servers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        if hasDnsIPv6 || assignedIPv6 != nil {
            let ipv6 = NEIPv6Settings(
                addresses: [clientIPv6],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        settings.mtu = 1500

        log.info("Applying tunnel settings ipv4=\(clientIPv4, privacy: .public)/255.255.255.0 ipv6=\(clientIPv6, privacy: .public) dns=\(servers.joined(separator: ","), privacy: .public)")

        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    private func startReadLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning else { return }

            var failedPackets = 0
            for packet in packets {
                if self.wsClient?.sendPacket(packet) != true {
                    failedPackets += 1
                }
            }

            if failedPackets > 0 {
                self.log.error("Failed to send \(failedPackets, privacy: .public) packets to websocket")
            }

            self.startReadLoop()
        }
    }

    private func handleIncomingPacketFromServer(_ packet: Data) {
        guard isRunning else { return }
        let protocolNumber = ipProtocolNumber(for: packet)
        packetFlow.writePackets([packet], withProtocols: [protocolNumber])
    }

    private func ipProtocolNumber(for packet: Data) -> NSNumber {
        guard let first = packet.first else {
            return AF_INET as NSNumber
        }
        let version = Int(first >> 4)
        return (version == 6 ? AF_INET6 : AF_INET) as NSNumber
    }

    private func scheduleStartTimeout(seconds: Int) {
        invalidateStartTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishStart(with: self?.makeError("WebSocket connection timeout"))
        }
        startTimeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds), execute: workItem)
    }

    private func invalidateStartTimeout() {
        stateQueue.sync {
            startTimeoutWorkItem?.cancel()
            startTimeoutWorkItem = nil
        }
    }

    private func finishStart(with error: Error?) {
        let completion: ((Error?) -> Void)? = stateQueue.sync {
            guard !didCompleteStart else { return nil }
            didCompleteStart = true
            startTimeoutWorkItem?.cancel()
            startTimeoutWorkItem = nil
            let pending = startCompletion
            startCompletion = nil
            return pending
        }

        if error != nil {
            isRunning = false
            _ = wsClient?.stop()
            wsClient = nil
        }

        completion?(error)
    }

    private func encodeResponse(_ response: TunnelControlResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "net.mrmidi.Fptn-tvOS.tunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

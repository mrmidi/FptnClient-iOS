//
//  PacketTunnelProvider.swift
//  Fptn-macOS-Tunnel
//
//  Created by Aleksandr Shabelnikov on 02.03.2026.
//

import Foundation
import NetworkExtension
import OSLog

private struct MacTunnelControlMessage: Codable {
    let action: MacTunnelMessageAction
    let logLevel: String?
}

private struct MacTunnelControlResponse: Codable {
    let ok: Bool
    let message: String
}

private enum MacTunnelMessageAction: String, Codable {
    case setLogLevel = "set_log_level"
    case ping
    case getStatus = "get_status"
}

private enum MacTunnelProviderConfig {
    static let server = "server"
    static let port = "port"
    static let accessToken = "accessToken"
    static let dnsIPv4 = "dnsIPv4"
    static let dnsIPv6 = "dnsIPv6"
    static let sni = "sni"
    static let md5Fingerprint = "md5Fingerprint"
    static let logLevel = "logLevel"
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "net.mrmidi.Fptn-macOS", category: "PacketTunnel")

    private let stateQueue = DispatchQueue(label: "net.mrmidi.Fptn-macOS.tunnel.state")
    private var wsClient: WebsocketClientBridge?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var didCompleteStart = false

    private var isRunning = false
    private var runtimeLogLevel = "warning"

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = config.providerConfiguration else {
            completionHandler(makeError("Missing providerConfiguration"))
            return
        }

        guard let server = providerConfig[MacTunnelProviderConfig.server] as? String,
              let port = providerConfig[MacTunnelProviderConfig.port] as? Int,
              let accessToken = providerConfig[MacTunnelProviderConfig.accessToken] as? String,
              let dnsIPv4 = providerConfig[MacTunnelProviderConfig.dnsIPv4] as? String,
              let sni = providerConfig[MacTunnelProviderConfig.sni] as? String,
              let md5 = providerConfig[MacTunnelProviderConfig.md5Fingerprint] as? String else {
            completionHandler(makeError("Incomplete providerConfiguration"))
            return
        }

        let dnsIPv6 = providerConfig[MacTunnelProviderConfig.dnsIPv6] as? String ?? "2606:4700:4700::1111"
        self.runtimeLogLevel = providerConfig[MacTunnelProviderConfig.logLevel] as? String ?? "warning"
        self.isRunning = false

        stateQueue.sync {
            self.startCompletion = completionHandler
            self.didCompleteStart = false
        }

        log.log("startTunnel server=\(server, privacy: .public):\(port, privacy: .public) sni=\(sni, privacy: .public) logLevel=\(self.runtimeLogLevel, privacy: .public)")
        log.debug("tokenLength=\(accessToken.count, privacy: .public) md5=\(md5, privacy: .private(mask: .hash))")

        let tunIPv4 = "10.8.0.2"
        let tunIPv4Gateway = "10.8.0.1"

        scheduleStartTimeout(seconds: 15)

        wsClient = WebsocketClientBridge(
            serverIP: server,
            serverPort: port,
            tunInterfaceIPv4: tunIPv4,
            sni: sni,
            accessToken: accessToken,
            md5Fingerprint: md5,
            packetCallback: { [weak self] packet in
                self?.handleIncomingPacketFromServer(packet)
            },
            connectedCallback: { [weak self] in
                self?.log.log("WebSocket connected; applying packet tunnel settings")
                self?.applyNetworkSettings(
                    tunIPv4: tunIPv4,
                    tunIPv4Gateway: tunIPv4Gateway,
                    dnsIPv4: dnsIPv4,
                    dnsIPv6: dnsIPv6
                ) { error in
                    if let error {
                        self?.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                        self?.finishStart(with: error)
                        return
                    }
                    self?.isRunning = true
                    self?.startReadLoop()
                    self?.finishStart(with: nil)
                }
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
        guard let message = try? JSONDecoder().decode(MacTunnelControlMessage.self, from: messageData) else {
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
            runtimeLogLevel = message.logLevel ?? "warning"
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
        completion: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIPv4Gateway)

        let ipv4 = NEIPv4Settings(addresses: [tunIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        var servers = [dnsIPv4]
        if !dnsIPv6.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           dnsIPv6.contains(":") {
            servers.append(dnsIPv6)
        }

        let dns = NEDNSSettings(servers: servers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        settings.mtu = 1500

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
            self.startTimeoutWorkItem?.cancel()
            self.startTimeoutWorkItem = nil
        }
    }

    private func finishStart(with error: Error?) {
        let completion: ((Error?) -> Void)? = stateQueue.sync {
            guard !self.didCompleteStart else { return nil }
            self.didCompleteStart = true
            self.startTimeoutWorkItem?.cancel()
            self.startTimeoutWorkItem = nil
            let pending = self.startCompletion
            self.startCompletion = nil
            return pending
        }

        if error != nil {
            isRunning = false
            _ = wsClient?.stop()
            wsClient = nil
        }

        completion?(error)
    }

    private func encodeResponse(_ response: MacTunnelControlResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "net.mrmidi.Fptn-macOS.tunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

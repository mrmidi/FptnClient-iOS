/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import NetworkExtension

// MARK: - PacketTunnelProvider

/// NEPacketTunnelProvider for the FptnVPN tunnel extension.
///
/// Lifecycle:
///   startTunnel  → reads providerConfiguration → connects WebSocket → sets tun settings
///   stopTunnel   → tears down WebSocket + tun
///   packetCallback → writes packets to the tun interface (device → server)
///   readPackets  → reads from tun (server → device) and forwards via WebSocket
class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Private state

    private var wsClient: WebsocketClientBridge?

    // MARK: - Tunnel lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        bootstrapLogging()
        logger.info("PacketTunnelProvider startTunnel")

        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = config.providerConfiguration else {
            let err = makeError("Missing providerConfiguration")
            logger.error("startTunnel failed: \(err.localizedDescription)")
            completionHandler(err)
            return
        }

        guard
            let serverIP   = providerConfig["server"]       as? String,
            let serverPort = providerConfig["port"]         as? Int,
            let accessToken = providerConfig["accessToken"] as? String,
            let dnsIPv4    = providerConfig["dnsIPv4"]      as? String,
            let sni        = providerConfig["sni"]          as? String,
            let md5        = providerConfig["md5Fingerprint"] as? String
        else {
            let err = makeError("Incomplete providerConfiguration")
            logger.error("startTunnel: \(err.localizedDescription)")
            completionHandler(err)
            return
        }

        let dnsIPv6 = providerConfig["dnsIPv6"] as? String ?? "fd00::1"
        let tunIPv4 = "10.8.0.2"
        let tunIPv4Gateway = "10.8.0.1"

        // Build WebSocket client
        wsClient = WebsocketClientBridge(
            serverIP: serverIP,
            serverPort: serverPort,
            tunInterfaceIPv4: tunIPv4,
            sni: sni,
            accessToken: accessToken,
            md5Fingerprint: md5,
            packetCallback: { [weak self] data in
                // Packets arriving from the server → write to tun interface
                self?.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
            },
            connectedCallback: { [weak self] in
                logger.info("WebSocket connected — applying network settings")
                self?.applyNetworkSettings(
                    tunIPv4: tunIPv4,
                    tunIPv4Gateway: tunIPv4Gateway,
                    dnsIPv4: dnsIPv4,
                    dnsIPv6: dnsIPv6,
                    completionHandler: completionHandler
                )
            }
        )

        guard wsClient?.start() == true else {
            let err = makeError("WebSocket start failed")
            logger.error("startTunnel: \(err.localizedDescription)")
            completionHandler(err)
            return
        }

        logger.debug("WebSocket start issued — waiting for connected callback")
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("PacketTunnelProvider stopTunnel reason=\(reason.rawValue)")
        wsClient?.stop()
        wsClient = nil
        completionHandler()
    }

    // MARK: - Network settings

    private func applyNetworkSettings(
        tunIPv4: String,
        tunIPv4Gateway: String,
        dnsIPv4: String,
        dnsIPv6: String,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIPv4Gateway)

        // IPv4
        let ipv4 = NEIPv4Settings(addresses: [tunIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // DNS
        let dns = NEDNSSettings(servers: [dnsIPv4, dnsIPv6])
        dns.matchDomains = [""]          // route all DNS through tunnel
        settings.dnsSettings = dns

        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                logger.error("setTunnelNetworkSettings error: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            logger.info("Tunnel network settings applied — starting packet read loop")
            self?.startReadLoop()
            completionHandler(nil)
        }
    }

    // MARK: - Packet read loop

    /// Continuously reads outbound packets from the tun interface and
    /// forwards them to the WebSocket (device → server direction).
    private func startReadLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for packet in packets {
                _ = self.wsClient?.sendPacket(packet)
            }
            // Schedule next read
            self.startReadLoop()
        }
    }

    // MARK: - App ↔ Extension IPC

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        logger.debug("handleAppMessage \(messageData.count) bytes")
        completionHandler?(messageData)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        logger.debug("PacketTunnelProvider sleep")
        completionHandler()
    }

    override func wake() {
        logger.debug("PacketTunnelProvider wake")
    }

    // MARK: - Helpers

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "org.fptn.tunnel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

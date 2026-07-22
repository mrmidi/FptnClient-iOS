//
//  PacketTunnelProvider.swift
//  Fptn-macOS-Tunnel
//
//  Created by Aleksandr Shabelnikov on 02.03.2026.
//

import Darwin
import Foundation
import Network
import NetworkExtension
import OSLog
import FptnSharedTunnel

private struct MacTunnelControlMessage: Codable {
    let action: MacTunnelMessageAction
    let logLevel: String?
    let initiator: String?
}

private struct MacTunnelControlResponse: Codable {
    let ok: Bool
    let message: String
}

private enum MacTunnelMessageAction: String, Codable {
    case setLogLevel = "set_log_level"
    case ping
    case getStatus = "get_status"
    case prepareStop = "prepare_stop"
}

private enum MacTunnelRuntimeState: String {
    case idle
    case starting
    case connected
    case reasserting
    case waitingForNetwork
    case stopping
    case failed
}

private struct MacTunnelConfiguration {
    let server: String
    let port: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String
    let sni: String
    let md5Fingerprint: String
    let logLevel: String
    let reconnectEnabled: Bool
    let maxReconnectAttempts: Int
    let reconnectDelaySeconds: Int
    let tunIPv4 = "10.8.0.2"
    let tunIPv4Gateway = "10.8.0.1"

    init?(providerConfig: [String: Any]) {
        guard let startupData = providerConfig[TunnelProviderConfigurationKey.startupV1] as? Data,
              startupData.count <= TunnelStartupConfigurationV1.maximumEncodedSize,
              let startup = try? JSONDecoder().decode(TunnelStartupConfigurationV1.self, from: startupData) else {
            return nil
        }

        self.server = startup.serverHost
        self.port = startup.serverPort
        self.accessToken = startup.accessToken
        self.dnsIPv4 = startup.dnsIPv4
        self.dnsIPv6 = startup.dnsIPv6 ?? "2606:4700:4700::1111"
        self.sni = startup.sni
        self.md5Fingerprint = startup.md5Fingerprint
        self.logLevel = startup.logLevel.rawValue
        switch startup.recoveryPolicy {
        case .none:
            self.reconnectEnabled = false
            self.maxReconnectAttempts = 0
            self.reconnectDelaySeconds = 0
        case let .automatic(policy):
            self.reconnectEnabled = true
            self.maxReconnectAttempts = policy.sameServerAttempts
            self.reconnectDelaySeconds = policy.reconnectDelaySeconds
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let log = Logger(subsystem: "net.mrmidi.Fptn-macOS", category: "PacketTunnel")
    private let eventQueue = DispatchQueue(label: "net.mrmidi.Fptn-macOS.tunnel.events")

    private var wsClient: WebsocketClientBridge?
    private var configuration: MacTunnelConfiguration?
    private var assignedIPv4: String?
    private var assignedIPv6: String?
    private var appliedIPv4: String?
    private var appliedIPv6: String?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var runtimeState: MacTunnelRuntimeState = .idle
    private var websocketGeneration = 0
    private var reconnectAttempt = 0
    private var shutdownRequested = false
    private var isNetworkPathSatisfied = true
    private var didApplyNetworkSettings = false
    private var isReadLoopActive = false

    private let runtimeReconnectDelayCapSeconds = 60

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = config.providerConfiguration,
              let runtimeConfig = MacTunnelConfiguration(providerConfig: providerConfig) else {
            completionHandler(makeError("Missing or incomplete providerConfiguration"))
            return
        }

        eventQueue.async {
            self.configuration = runtimeConfig
            self.startCompletion = completionHandler
            self.runtimeState = .starting
            self.websocketGeneration = 0
            self.reconnectAttempt = 0
            self.shutdownRequested = false
            self.isNetworkPathSatisfied = true
            self.didApplyNetworkSettings = false
            self.isReadLoopActive = false
            self.assignedIPv4 = nil
            self.assignedIPv6 = nil
            self.appliedIPv4 = nil
            self.appliedIPv6 = nil

            self.log.log("startTunnel server=\(runtimeConfig.server, privacy: .public):\(runtimeConfig.port, privacy: .public) sni=\(runtimeConfig.sni, privacy: .public) logLevel=\(runtimeConfig.logLevel, privacy: .public)")
            self.log.debug("tokenLength=\(runtimeConfig.accessToken.count, privacy: .public) md5=\(runtimeConfig.md5Fingerprint, privacy: .private(mask: .hash))")

            self.startPathMonitor()
            self.scheduleStartTimeout(seconds: 15)
            self.startWebSocket(using: runtimeConfig, context: "initial_start")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        eventQueue.async {
            self.shutdownRequested = true
            self.runtimeState = .stopping
            self.isReadLoopActive = false
            self.cancelStartTimeout()
            self.cancelPendingReconnect()
            self.stopPathMonitor()
            self.finishStart(with: self.makeError("Tunnel stopped before startup completed"))
            self.replaceWebSocketClient(with: nil, stopCurrent: true)
            self.log.log("stopTunnel reason=\(reason.rawValue, privacy: .public)")
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        eventQueue.async {
            guard let message = try? JSONDecoder().decode(MacTunnelControlMessage.self, from: messageData) else {
                completionHandler?(self.encodeResponse(.init(ok: false, message: "invalid_payload")))
                return
            }

            switch message.action {
            case .ping:
                completionHandler?(self.encodeResponse(.init(ok: true, message: "pong")))
            case .getStatus:
                completionHandler?(self.encodeResponse(.init(ok: true, message: self.runtimeState.rawValue)))
            case .setLogLevel:
                completionHandler?(self.encodeResponse(.init(ok: true, message: "log_level_updated")))
            case .prepareStop:
                if message.initiator == "app_disconnect" {
                    self.shutdownRequested = true
                    self.isReadLoopActive = false
                    self.cancelPendingReconnect()
                    self.log.info("Marked local stop initiator via IPC: app_disconnect; reconnect will be suppressed")
                }
                completionHandler?(self.encodeResponse(.init(ok: true, message: "stop_initiator_recorded")))
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log.debug("sleep")
        completionHandler()
    }

    override func wake() {
        log.debug("wake")
    }

    private func startWebSocket(using configuration: MacTunnelConfiguration, context: String) {
        guard !shutdownRequested else {
            log.info("Skipping WebSocket start context=\(context, privacy: .public) because shutdown was requested")
            return
        }

        websocketGeneration += 1
        let generation = websocketGeneration
        let client = WebsocketClientBridge(
            serverIP: configuration.server,
            serverPort: configuration.port,
            tunInterfaceIPv4: configuration.tunIPv4,
            sni: configuration.sni,
            accessToken: configuration.accessToken,
            md5Fingerprint: configuration.md5Fingerprint,
            packetCallback: { [weak self] packet in
                self?.eventQueue.async {
                    self?.handleIncomingPacketFromServer(packet, generation: generation)
                }
            },
            connectedCallback: { [weak self] in
                self?.eventQueue.async {
                    self?.handleTransportConnected(generation: generation)
                }
            },
            disconnectedCallback: { [weak self] wasConnected, reason in
                self?.eventQueue.async {
                    self?.handleTransportDisconnected(
                        generation: generation,
                        wasConnected: wasConnected,
                        reason: reason
                    )
                }
            },
            ipAssignedCallback: { [weak self] ipv4, ipv6 in
                self?.eventQueue.async {
                    guard let self else { return }
                    self.assignedIPv4 = ipv4
                    self.assignedIPv6 = ipv6
                    self.log.info("IP assignment received from bridge: IPv4=\(ipv4, privacy: .public), IPv6=\(ipv6, privacy: .public)")
                }
            }
        )

        replaceWebSocketClient(with: client, stopCurrent: false)
        guard client.start() else {
            replaceWebSocketClient(with: nil, stopCurrent: false)
            handleTransportDisconnected(generation: generation, wasConnected: false, reason: "WebSocket start failed")
            return
        }

        log.debug("WebSocket start issued context=\(context, privacy: .public) generation=\(generation, privacy: .public)")
    }

    private func handleTransportConnected(generation: Int) {
        guard generation == websocketGeneration else {
            log.info("Ignoring stale websocket connected callback generation=\(generation, privacy: .public)")
            return
        }
        guard !shutdownRequested else {
            replaceWebSocketClient(with: nil, stopCurrent: true)
            return
        }
        guard let configuration else {
            finishStart(with: makeError("Transport connected without runtime configuration"))
            return
        }

        log.log("WebSocket connected generation=\(generation, privacy: .public)")
        
        let ipChanged = (assignedIPv4 != appliedIPv4) || (assignedIPv6 != appliedIPv6)
        let shouldApplySettings = (!didApplyNetworkSettings && runtimeState == .starting) || (runtimeState == .reasserting && ipChanged)
        
        if shouldApplySettings {
            let clientIPv4 = assignedIPv4 ?? configuration.tunIPv4
            let clientIPv6 = assignedIPv6 ?? "fd00::1"
            applyNetworkSettings(configuration: configuration) { [weak self] error in
                self?.eventQueue.async {
                    guard let self else { return }
                    if let error {
                        self.runtimeState = .failed
                        self.finishStart(with: error)
                        self.replaceWebSocketClient(with: nil, stopCurrent: true)
                        return
                    }
                    self.appliedIPv4 = clientIPv4
                    self.appliedIPv6 = clientIPv6
                    self.didApplyNetworkSettings = true
                    self.runtimeState = .connected
                    self.reconnectAttempt = 0
                    self.isReadLoopActive = true
                    self.startReadLoop()
                    self.finishStart(with: nil)
                }
            }
            return
        }

        runtimeState = .connected
        reconnectAttempt = 0
        isReadLoopActive = true
        startReadLoop()
    }

    private func handleTransportDisconnected(generation: Int, wasConnected: Bool, reason: String) {
        guard generation == websocketGeneration else {
            log.info("Ignoring stale websocket disconnected callback generation=\(generation, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }

        log.warning("WebSocket disconnected generation=\(generation, privacy: .public) wasConnected=\(wasConnected, privacy: .public) reason=\(reason, privacy: .public)")
        replaceWebSocketClient(with: nil, stopCurrent: false)
        cancelStartTimeout()

        guard !shutdownRequested else {
            runtimeState = .stopping
            log.info("Suppressing reconnect because shutdown was requested")
            return
        }

        guard runtimeState != .starting else {
            // If the path is not yet satisfied at startup, wait for network instead of
            // hard-failing. scheduleReconnect() transitions to .waitingForNetwork and the
            // path monitor will retry once connectivity is restored.
            if !isNetworkPathSatisfied {
                scheduleReconnect()
            } else {
                runtimeState = .failed
                finishStart(with: makeError(reason))
            }
            return
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let configuration else {
            log.info("Skipping reconnect schedule because runtime configuration is missing")
            return
        }
        guard configuration.reconnectEnabled else {
            log.info("Skipping reconnect schedule because reconnect is disabled")
            return
        }
        guard !shutdownRequested else {
            log.info("Skipping reconnect schedule because shutdown was requested")
            return
        }

        reconnectAttempt += 1
        let attempt = reconnectAttempt
        if !isNetworkPathSatisfied {
            runtimeState = .waitingForNetwork
            log.warning("Waiting for network path before reconnect attempt \(attempt, privacy: .public)")
            return
        }

        runtimeState = .reasserting
        let generation = websocketGeneration
        let delaySeconds = computedReconnectDelaySeconds(
            attempt: attempt,
            baseDelaySeconds: configuration.reconnectDelaySeconds
        )
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.eventQueue.async {
                self?.performReconnectAttempt(expectedGeneration: generation)
            }
        }
        reconnectWorkItem = workItem

        if configuration.maxReconnectAttempts != 0 && attempt > configuration.maxReconnectAttempts {
            log.warning("Reconnect attempt \(attempt, privacy: .public) exceeded configured budget \(configuration.maxReconnectAttempts, privacy: .public); continuing runtime recovery with backoff \(delaySeconds, privacy: .public)s")
        } else {
            log.warning("Scheduling reconnect attempt \(attempt, privacy: .public) after \(delaySeconds, privacy: .public)s")
        }
        eventQueue.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
    }

    private func performReconnectAttempt(expectedGeneration: Int) {
        guard let configuration, !shutdownRequested, expectedGeneration == websocketGeneration else {
            log.info("Skipping reconnect attempt because it is stale or shutdown was requested")
            return
        }
        guard isNetworkPathSatisfied else {
            runtimeState = .waitingForNetwork
            log.warning("Reconnect delayed because network path is unsatisfied")
            return
        }

        reconnectWorkItem = nil
        log.warning("Starting reconnect attempt \(self.reconnectAttempt, privacy: .public)")
        startWebSocket(using: configuration, context: "reconnect_attempt_\(self.reconnectAttempt)")
    }

    private func applyNetworkSettings(
        configuration: MacTunnelConfiguration,
        completion: @escaping (Error?) -> Void
    ) {
        let clientIPv4 = assignedIPv4 ?? configuration.tunIPv4
        let gatewayIPv4 = assignedIPv4 != nil ? configuration.dnsIPv4 : configuration.tunIPv4Gateway
        let clientIPv6 = assignedIPv6 ?? "fd00::1"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gatewayIPv4)

        let ipv4 = NEIPv4Settings(addresses: [clientIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        var servers = [configuration.dnsIPv4]
        let hasDnsIPv6 = !configuration.dnsIPv6.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && configuration.dnsIPv6.contains(":")
        if hasDnsIPv6 {
            servers.append(configuration.dnsIPv6)
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

        settings.mtu = 1400

        log.info("Applying tunnel settings ipv4=\(clientIPv4, privacy: .public)/255.255.255.0 ipv6=\(clientIPv6, privacy: .public) dns=\(servers.joined(separator: ","), privacy: .public) mtu=1400")

        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    private func startReadLoop() {
        guard isReadLoopActive else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            self?.eventQueue.async {
                guard let self, self.isReadLoopActive else { return }

                var failedPackets = 0
                let client = self.wsClient
                for packet in packets {
                    if client?.sendPacket(packet) != true {
                        failedPackets += 1
                    }
                }

                if failedPackets > 0 {
                    self.log.error("Failed to send \(failedPackets, privacy: .public) packets to websocket")
                }

                self.startReadLoop()
            }
        }
    }

    private func handleIncomingPacketFromServer(_ packet: Data, generation: Int) {
        guard generation == websocketGeneration, isReadLoopActive else { return }
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
        cancelStartTimeout()
        let generation = websocketGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.eventQueue.async {
                guard let self, generation == self.websocketGeneration, !self.shutdownRequested else { return }
                self.runtimeState = .failed
                self.finishStart(with: self.makeError("WebSocket connection timeout"))
                self.replaceWebSocketClient(with: nil, stopCurrent: true)
            }
        }
        startTimeoutWorkItem = workItem
        eventQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: workItem)
    }

    private func cancelStartTimeout() {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
    }

    private func cancelPendingReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func startPathMonitor() {
        stopPathMonitor()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.eventQueue.async {
                self?.handleNetworkPathChanged(isSatisfied: path.status == .satisfied)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: eventQueue)
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handleNetworkPathChanged(isSatisfied: Bool) {
        let previous = isNetworkPathSatisfied
        isNetworkPathSatisfied = isSatisfied
        guard previous != isSatisfied else { return }

        log.info("Network path satisfied=\(isSatisfied, privacy: .public)")
        if isSatisfied && runtimeState == .waitingForNetwork {
            scheduleReconnect()
        }
    }

    private func replaceWebSocketClient(with newClient: WebsocketClientBridge?, stopCurrent: Bool) {
        let previous = wsClient
        wsClient = newClient
        if stopCurrent {
            _ = previous?.stop()
        }
    }

    private func computedReconnectDelaySeconds(attempt: Int, baseDelaySeconds: Int) -> Int {
        let safeBaseDelay = max(1, baseDelaySeconds)
        let backoffStep = min(max(0, attempt - 1), 5)
        let multiplier = 1 << backoffStep
        return min(runtimeReconnectDelayCapSeconds, safeBaseDelay * multiplier)
    }

    private func finishStart(with error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        cancelStartTimeout()

        if error != nil {
            isReadLoopActive = false
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

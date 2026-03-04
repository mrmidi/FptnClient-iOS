import Foundation
import FptnSharedCore

typealias MacVPNServer = FptnSharedCore.VPNServer
typealias MacTokenPayload = FptnSharedCore.FPTNToken

extension MacVPNServer {
    init(name: String, host: String, port: Int, md5_fingerprint: String) {
        self.init(name: name, host: host, port: port, md5Fingerprint: md5_fingerprint)
    }

    var md5_fingerprint: String {
        md5Fingerprint
    }
}

extension MacTokenPayload {
    init(version: Int, service_name: String, username: String, password: String, servers: [MacVPNServer]) {
        self.init(
            version: version,
            serviceName: service_name,
            username: username,
            password: password,
            servers: servers
        )
    }

    var service_name: String {
        serviceName
    }
}

enum MacTunnelMessageAction: String, Codable {
    case setLogLevel = "set_log_level"
    case ping
    case getStatus = "get_status"
}

struct MacTunnelControlMessage: Codable {
    let action: MacTunnelMessageAction
    let logLevel: String?

    init(action: MacTunnelMessageAction, logLevel: String? = nil) {
        self.action = action
        self.logLevel = logLevel
    }
}

struct MacTunnelControlResponse: Codable {
    let ok: Bool
    let message: String
}

enum MacTunnelProviderConfig {
    static let server = "server"
    static let port = "port"
    static let accessToken = "accessToken"
    static let dnsIPv4 = "dnsIPv4"
    static let dnsIPv6 = "dnsIPv6"
    static let sni = "sni"
    static let md5Fingerprint = "md5Fingerprint"
    static let logLevel = "logLevel"
}

struct MacTunnelProviderPayload {
    let server: String
    let port: Int
    let accessToken: String
    let dnsIPv4: String
    let dnsIPv6: String
    let sni: String
    let md5Fingerprint: String
    let logLevel: String

    func asDictionary() -> [String: Any] {
        [
            MacTunnelProviderConfig.server: server,
            MacTunnelProviderConfig.port: port,
            MacTunnelProviderConfig.accessToken: accessToken,
            MacTunnelProviderConfig.dnsIPv4: dnsIPv4,
            MacTunnelProviderConfig.dnsIPv6: dnsIPv6,
            MacTunnelProviderConfig.sni: sni,
            MacTunnelProviderConfig.md5Fingerprint: md5Fingerprint,
            MacTunnelProviderConfig.logLevel: logLevel
        ]
    }
}

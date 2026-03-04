import Foundation

struct MacVPNServer: Codable, Identifiable, Hashable {
    var id: String { "\(host):\(port)" }
    let name: String
    let host: String
    let port: Int
    let md5_fingerprint: String
}

struct MacTokenPayload: Codable {
    let version: Int
    let service_name: String
    let username: String
    let password: String
    let servers: [MacVPNServer]
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

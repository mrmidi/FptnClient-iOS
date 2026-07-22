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
    case prepareStop = "prepare_stop"
}

struct MacTunnelControlMessage: Codable {
    let action: MacTunnelMessageAction
    let logLevel: String?
    let initiator: String?

    init(action: MacTunnelMessageAction, logLevel: String? = nil, initiator: String? = nil) {
        self.action = action
        self.logLevel = logLevel
        self.initiator = initiator
    }
}

struct MacTunnelControlResponse: Codable {
    let ok: Bool
    let message: String
}

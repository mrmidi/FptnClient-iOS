import Foundation
import FptnSharedCore

typealias TvVPNServer = FptnSharedCore.VPNServer
typealias TvTokenPayload = FptnSharedCore.FPTNToken

extension TvVPNServer {
    init(name: String, host: String, port: Int, md5_fingerprint: String) {
        self.init(name: name, host: host, port: port, md5Fingerprint: md5_fingerprint)
    }

    var md5_fingerprint: String {
        md5Fingerprint
    }
}

extension TvTokenPayload {
    init(version: Int, service_name: String, username: String, password: String, servers: [TvVPNServer]) {
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

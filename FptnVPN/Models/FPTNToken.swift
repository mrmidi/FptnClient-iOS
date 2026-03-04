/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore

typealias FPTNToken = FptnSharedCore.FPTNToken

extension FPTNToken {
    init(version: Int, service_name: String, username: String, password: String, servers: [VPNServer]) {
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

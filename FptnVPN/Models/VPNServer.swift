///*=============================================================================
//Copyright (c) 2024-2025 Stas Skokov
//
//Distributed under the MIT License (https://opensource.org/licenses/MIT)
//=============================================================================*/

import Foundation
import FptnSharedCore

typealias VPNServer = FptnSharedCore.VPNServer

extension VPNServer {
    init(name: String, host: String, md5_fingerprint: String, port: Int) {
        self.init(name: name, host: host, port: port, md5Fingerprint: md5_fingerprint)
    }

    var md5_fingerprint: String {
        md5Fingerprint
    }
}

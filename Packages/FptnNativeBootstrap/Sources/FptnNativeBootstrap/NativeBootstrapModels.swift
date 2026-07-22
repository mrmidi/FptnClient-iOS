/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore

public struct LoginRequest: Encodable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct LoginResponse: Decodable, Sendable {
    public let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

public struct DNSResponse: Decodable, Sendable {
    public let dnsIPv4: String
    public let dnsIPv6: String?

    enum CodingKeys: String, CodingKey {
        case dnsIPv4 = "dns"
        case dnsIPv6 = "dns_ipv6"
    }

    public init(dnsIPv4: String, dnsIPv6: String?) {
        self.dnsIPv4 = dnsIPv4
        self.dnsIPv6 = dnsIPv6
    }
}

public struct NativeHTTPResponse: Sendable {
    public let code: Int
    public let body: String
    public let errmsg: String

    public init(code: Int, body: String, errmsg: String) {
        self.code = code
        self.body = body
        self.errmsg = errmsg
    }
}

public protocol NativeBootstrapClient: Sendable {
    func post(path: String, body: String, timeoutSeconds: Int32) async -> NativeHTTPResponse
    func get(path: String, timeoutSeconds: Int32) async -> NativeHTTPResponse
    func cancel()
}

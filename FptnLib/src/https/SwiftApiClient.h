/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#pragma once

#include <string>
#include <cstdint>
#include <stdbool.h>
#include <swift/bridging>

namespace fptn::protocol::https { class ApiClient; }

// PR0: SWIFT_NONCOPYABLE makes Swift import this as ~Copyable,
// removing the implicitly-unwrapped-optional workaround in Swift wrappers.
class SWIFT_NONCOPYABLE SwiftApiClient {
public:
    struct Response {
        std::string body;
        int code;
        std::string errmsg;
    };

    struct HandshakeResult {
        bool reachable;
        int latency_ms;
        std::string errmsg;
    };

    SwiftApiClient(
        const std::string& host,
        int port,
        const std::string& sni,
        const std::string& md5_fingerprint,
        const std::string& censorship_strategy,
        const std::string& name = ""
    );

    ~SwiftApiClient();

    SwiftApiClient(const SwiftApiClient&) = delete;
    SwiftApiClient& operator=(const SwiftApiClient&) = delete;
    SwiftApiClient(SwiftApiClient&& other) noexcept;
    SwiftApiClient& operator=(SwiftApiClient&& other) noexcept;

    Response get(const std::string& path, int timeout) const;
    Response post(const std::string& path, const std::string& body, int timeout) const;
    HandshakeResult testHandshake(int timeout) const;

private:
    fptn::protocol::https::ApiClient* client_;
};

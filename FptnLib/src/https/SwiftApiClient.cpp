/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#include "SwiftApiClient.h"
#include "https/api_client/api_client.h"

#include <cctype>
#include <chrono>
#include <cstring>
#include <string>

namespace {

std::string normalized_strategy_name(const char* value) {
    std::string strategy = value ? value : "";
    const auto option_end = strategy.find(';');
    if (option_end != std::string::npos) {
        strategy.erase(option_end);
    }
    for (char& ch : strategy) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return strategy;
}

fptn::protocol::https::CensorshipStrategy parse_censorship_strategy(const char* value) {
    using fptn::protocol::https::CensorshipStrategy;

    const std::string strategy = normalized_strategy_name(value);
    if (strategy == "obfuscation" || strategy == "tls" || strategy == "tls_obfuscator" ||
        strategy == "tls-obfuscator" || strategy == "ktlsobfuscator") {
        return CensorshipStrategy::kTlsObfuscator;
    }
    if (strategy == "reality" || strategy == "sni_reality" ||
        strategy == "sni-reality" || strategy == "ksnirealitymode") {
        return CensorshipStrategy::kSniRealityMode;
    }
    if (strategy == "chrome147" || strategy == "sni_reality_chrome147" ||
        strategy == "sni-reality-chrome147") {
        return CensorshipStrategy::kSniRealityModeChrome147;
    }
    if (strategy == "chrome146" || strategy == "sni_reality_chrome146" ||
        strategy == "sni-reality-chrome146") {
        return CensorshipStrategy::kSniRealityModeChrome146;
    }
    if (strategy == "chrome145" || strategy == "sni_reality_chrome145" ||
        strategy == "sni-reality-chrome145") {
        return CensorshipStrategy::kSniRealityModeChrome145;
    }
    if (strategy == "firefox149" || strategy == "sni_reality_firefox149" ||
        strategy == "sni-reality-firefox149") {
        return CensorshipStrategy::kSniRealityModeFirefox149;
    }
    if (strategy == "yandex26" || strategy == "sni_reality_yandex26" ||
        strategy == "sni-reality-yandex26") {
        return CensorshipStrategy::kSniRealityModeYandex26;
    }
    if (strategy == "yandex25" || strategy == "sni_reality_yandex25" ||
        strategy == "sni-reality-yandex25") {
        return CensorshipStrategy::kSniRealityModeYandex25;
    }
    if (strategy == "yandex24" || strategy == "sni_reality_yandex24" ||
        strategy == "sni-reality-yandex24") {
        return CensorshipStrategy::kSniRealityModeYandex24;
    }
    if (strategy == "safari26" || strategy == "sni_reality_safari26" ||
        strategy == "sni-reality-safari26") {
        return CensorshipStrategy::kSniRealityModeSafari26;
    }
    return CensorshipStrategy::kSni;
}

std::string safe_string(const char* value) {
    return (value != nullptr) ? std::string(value) : std::string();
}

} // anonymous namespace

SwiftApiClient::SwiftApiClient(
    const std::string& host,
    int port,
    const std::string& sni,
    const std::string& md5_fingerprint,
    const std::string& censorship_strategy
)
    : client_(nullptr)
{
    try {
        client_ = new fptn::protocol::https::ApiClient(
            host,
            port,
            sni,
            md5_fingerprint,
            parse_censorship_strategy(censorship_strategy.c_str())
        );
    } catch (const std::exception& e) {
        client_ = nullptr;
    } catch (...) {
        client_ = nullptr;
    }
}

SwiftApiClient::~SwiftApiClient() {
    delete client_;
}

SwiftApiClient::SwiftApiClient(SwiftApiClient&& other) noexcept : client_(other.client_) {
    other.client_ = nullptr;
}

SwiftApiClient& SwiftApiClient::operator=(SwiftApiClient&& other) noexcept {
    if (this != &other) {
        delete client_;
        client_ = other.client_;
        other.client_ = nullptr;
    }
    return *this;
}

SwiftApiClient::Response SwiftApiClient::get(const std::string& path, int timeout) const {
    if (!client_) {
        return Response{"", -1, "client not initialized"};
    }
    try {
        auto resp = client_->Get(path, timeout);
        return Response{resp.body, resp.code, resp.errmsg};
    } catch (const std::exception& e) {
        return Response{"", -1, std::string("exception: ") + e.what()};
    } catch (...) {
        return Response{"", -1, "unknown exception"};
    }
}

SwiftApiClient::Response SwiftApiClient::post(
    const std::string& path,
    const std::string& body,
    int timeout
) const {
    if (!client_) {
        return Response{"", -1, "client not initialized"};
    }
    try {
        auto resp = client_->Post(path, body, "application/json", timeout);
        return Response{resp.body, resp.code, resp.errmsg};
    } catch (const std::exception& e) {
        return Response{"", -1, std::string("exception: ") + e.what()};
    } catch (...) {
        return Response{"", -1, "unknown exception"};
    }
}

SwiftApiClient::HandshakeResult SwiftApiClient::testHandshake(int timeout) const {
    if (!client_) {
        return HandshakeResult{false, -1, "client not initialized"};
    }
    try {
        auto start = std::chrono::steady_clock::now();
        bool reachable = client_->TestHandshake(timeout);
        auto end = std::chrono::steady_clock::now();
        int latency = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
        );
        if (!reachable) {
            return HandshakeResult{false, latency, "Handshake failed"};
        }
        return HandshakeResult{true, latency, ""};
    } catch (const std::exception& e) {
        return HandshakeResult{false, -1, std::string("exception: ") + e.what()};
    } catch (...) {
        return HandshakeResult{false, -1, "unknown exception"};
    }
}

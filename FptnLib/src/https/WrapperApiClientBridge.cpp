#include <cctype>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <string>

#include "WrapperApiClientBridge.h"

#include "https/api_client/api_client.h"

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

fptn::protocol::https::CensorshipStrategy parse_censorship_strategy(
    const char* value) {
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
    return value ? std::string(value) : std::string();
}

} // namespace

extern "C" {

ApiClientHandle apiClientCreate(const char* host,
                                int port,
                                const char* sni,
                                const char* md5_fingerprint,
                                const char* censorship_strategy) {
    try {
        auto client = new fptn::protocol::https::ApiClient(
            safe_string(host),
            port,
            safe_string(sni),
            safe_string(md5_fingerprint),
            parse_censorship_strategy(censorship_strategy)
        );
        return static_cast<ApiClientHandle>(client);
    } catch (const std::exception& e) {
        // Log error if needed
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

void apiClientDestroy(ApiClientHandle handle) {
    if (handle) {
        auto client = static_cast<fptn::protocol::https::ApiClient*>(handle);
        delete client;
    }
}

CApiClientResponse apiClientGet(ApiClientHandle handle, const char* handle_str, int timeout) {
    CApiClientResponse response = {nullptr, 0, nullptr};
    if (!handle) {
        response.errmsg = strdup("Invalid handle");
        return response;
    }
    try {
        auto client = static_cast<fptn::protocol::https::ApiClient*>(handle);
        const auto cpp_response = client->Get(handle_str, timeout);
        
        response.code = cpp_response.code;
        
        if (!cpp_response.body.empty()) {
            response.body = strdup(cpp_response.body.c_str());
        }
        if (!cpp_response.errmsg.empty()) {
            response.errmsg = strdup(cpp_response.errmsg.c_str());
        }
    } catch (const std::exception& e) {
        response.errmsg = strdup(e.what());
    } catch (...) {
        response.errmsg = strdup("Unknown error occurred");
    }
    return response;
}

CApiClientResponse apiClientPost(ApiClientHandle handle, const char* handle_str, const char* request, int timeout) {
    CApiClientResponse response = {nullptr, 0, nullptr};
    if (!handle) {
        response.errmsg = strdup("Invalid handle");
        return response;
    }
    try {
        auto client = static_cast<fptn::protocol::https::ApiClient*>(handle);
        const auto cpp_response = client->Post(handle_str, request, "application/json", timeout);
        response.code = cpp_response.code;
        if (!cpp_response.body.empty()) {
            response.body = strdup(cpp_response.body.c_str());
        }
        if (!cpp_response.errmsg.empty()) {
            response.errmsg = strdup(cpp_response.errmsg.c_str());
        }
    } catch (const std::exception& e) {
        response.errmsg = strdup(e.what());
    } catch (...) {
        response.errmsg = strdup("Unknown error occurred");
    }
    return response;
}

CApiClientHandshakeResult apiClientTestHandshake(ApiClientHandle handle, int timeout) {
    CApiClientHandshakeResult result = {false, -1, nullptr};
    if (!handle) {
        result.errmsg = strdup("Invalid handle");
        return result;
    }
    try {
        auto client = static_cast<fptn::protocol::https::ApiClient*>(handle);
        const auto start = std::chrono::steady_clock::now();
        result.reachable = client->TestHandshake(timeout);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start);
        result.latency_ms = static_cast<int>(elapsed.count());
        if (!result.reachable) {
            result.errmsg = strdup("Handshake failed");
        }
    } catch (const std::exception& e) {
        result.errmsg = strdup(e.what());
    } catch (...) {
        result.errmsg = strdup("Unknown error occurred");
    }
    return result;
}

void apiClientResponseFree(CApiClientResponse response) {
    if (response.body) {
        free(response.body);
    }
    if (response.errmsg) {
        free(response.errmsg);
    }
}

void apiClientHandshakeResultFree(CApiClientHandshakeResult result) {
    if (result.errmsg) {
        free(result.errmsg);
    }
}

} // extern "C"

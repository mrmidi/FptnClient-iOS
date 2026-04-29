/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#include <atomic>
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <mach/mach.h>

#include <fptn-protocol-lib/https/websocket_client/websocket_client.h>

#ifndef FPTN_VERSION
#define FPTN_VERSION "unknown"
#endif

#include "common/logger/logger.h"
#include "WrapperWebsocketClientBridge.h"

#ifndef FPTN_CLIENT_DEFAULT_ADDRESS_IP6
#define FPTN_CLIENT_DEFAULT_ADDRESS_IP6 "fd00::1"
#endif

constexpr const int kDefaultIdleTimeoutSeconds = 60;

struct WebsocketClientWrapper {
    IPPacketCallback packet_callback;
    ConnectionCallback connected_callback;
    DisconnectedCallback disconnected_callback;
    void* context;
    std::shared_ptr<fptn::protocol::https::WebsocketClient> client;
    std::thread client_thread;
    std::atomic<bool> running{false};
    std::mutex mutex;
    int idle_timeout_seconds;

    std::string server_ip;
    int server_port;
    std::string tun_ipv4;
    std::string tun_ipv6;
    std::string sni;
    std::string access_token;
    std::string md5_fingerprint;
    std::string censorship_strategy;
    std::string last_error;
    std::string last_disconnect_reason;
    std::atomic<int64_t> received_packet_count{0};
    std::atomic<int64_t> received_byte_count{0};
    std::atomic<int64_t> callback_enter_count{0};
    std::atomic<int64_t> callback_exit_count{0};
    std::atomic<int64_t> callback_byte_count{0};
    std::atomic<bool> in_packet_callback{false};

    WebsocketClientWrapper(
        IPPacketCallback p_callback,
        ConnectionCallback c_callback,
        DisconnectedCallback d_callback,
        void* ctx
    )
        : packet_callback(p_callback),
          connected_callback(c_callback),
          disconnected_callback(d_callback),
          context(ctx),
          idle_timeout_seconds(kDefaultIdleTimeoutSeconds) {}
};

int parse_int_option(const std::string& options,
                     std::string_view key,
                     int default_value) {
    const std::string prefix = std::string(key) + "=";
    std::size_t segment_start = 0;
    while (segment_start <= options.size()) {
        const std::size_t segment_end = options.find(';', segment_start);
        const std::string segment = options.substr(
            segment_start,
            segment_end == std::string::npos ? std::string::npos : segment_end - segment_start);
        if (segment.rfind(prefix, 0) == 0) {
            const char* value = segment.c_str() + prefix.size();
            char* end_ptr = nullptr;
            const long parsed = std::strtol(value, &end_ptr, 10);
            if (end_ptr != value && parsed >= 0 && parsed <= INT32_MAX) {
                return static_cast<int>(parsed);
            }
            return default_value;
        }
        if (segment_end == std::string::npos) {
            break;
        }
        segment_start = segment_end + 1;
    }
    return default_value;
}

std::string parse_string_option(const std::string& options,
                                std::string_view key,
                                std::string default_value) {
    const std::string prefix = std::string(key) + "=";
    std::size_t segment_start = 0;
    while (segment_start <= options.size()) {
        const std::size_t segment_end = options.find(';', segment_start);
        const std::string segment = options.substr(
            segment_start,
            segment_end == std::string::npos ? std::string::npos : segment_end - segment_start);
        if (segment.rfind(prefix, 0) == 0) {
            const std::string value = segment.substr(prefix.size());
            return value.empty() ? default_value : value;
        }
        if (segment_end == std::string::npos) {
            break;
        }
        segment_start = segment_end + 1;
    }
    return default_value;
}

namespace {
uint64_t current_resident_size_bytes() {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        reinterpret_cast<task_info_t>(&info),
        &count
    );
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<uint64_t>(info.resident_size);
}

uint64_t current_phys_footprint_bytes() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        reinterpret_cast<task_info_t>(&info),
        &count
    );
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<uint64_t>(info.phys_footprint);
}

std::string normalized_strategy_name(std::string value) {
    const auto option_end = value.find(';');
    if (option_end != std::string::npos) {
        value.erase(option_end);
    }
    for (char& ch : value) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

fptn::protocol::https::CensorshipStrategy parse_censorship_strategy(
    const std::string& value) {
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

void packet_callback_adapter(fptn::common::network::IPPacketPtr packet,
                             void* user_data) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(user_data);
    if (wrapper && wrapper->packet_callback && packet) {
        const auto* raw_packet = packet->GetRawPacket();
        const auto* data = static_cast<const uint8_t*>(raw_packet->getRawData());
        const auto len = raw_packet->getRawDataLen();
        const auto packet_count = wrapper->received_packet_count.fetch_add(1) + 1;
        const auto total_bytes = wrapper->received_byte_count.fetch_add(len) + len;
        wrapper->callback_enter_count.fetch_add(1);
        wrapper->callback_byte_count.fetch_add(len);
        wrapper->in_packet_callback = true;
        if (packet_count == 1 || packet_count % 500 == 0) {
            SPDLOG_WARN(
                "WebSocket bridge memory rss={}MB footprint={}MB received_packets={} received_bytes={} callback_enter={} callback_exit={}",
                current_resident_size_bytes() / 1024 / 1024,
                current_phys_footprint_bytes() / 1024 / 1024,
                packet_count,
                total_bytes,
                wrapper->callback_enter_count.load(),
                wrapper->callback_exit_count.load()
            );
        }
        wrapper->packet_callback(data, len, wrapper->context);
        wrapper->in_packet_callback = false;
        wrapper->callback_exit_count.fetch_add(1);
    }
}

void connected_callback_adapter(void* user_data) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(user_data);
    if (wrapper && wrapper->connected_callback) {
        wrapper->connected_callback(wrapper->context);
    }
}

void disconnected_callback_adapter(bool was_connected,
                                   const std::string& reason,
                                   void* user_data) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(user_data);
    if (wrapper && wrapper->disconnected_callback) {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            wrapper->last_disconnect_reason = reason;
            if (!was_connected) {
                wrapper->last_error = reason;
            }
        }
        wrapper->disconnected_callback(
            was_connected,
            reason.c_str(),
            wrapper->context
        );
    }
}

void initialize_logger_once() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        (void)fptn::logger::init("fptn-ios-tunnel");
    });
}

void client_run_thread(WebsocketClientWrapper* wrapper) {
    initialize_logger_once();

    try {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            if (!wrapper->running) {
                return;
            }

            wrapper->client = std::make_shared<fptn::protocol::https::WebsocketClient>(
                fptn::common::network::IPv4Address::Create(wrapper->server_ip),
                wrapper->server_port,
                fptn::common::network::IPv4Address::Create(wrapper->tun_ipv4),
                fptn::common::network::IPv6Address::Create(wrapper->tun_ipv6),
                [wrapper](auto packet) {
                    packet_callback_adapter(std::move(packet), wrapper);
                },
                wrapper->sni,
                wrapper->access_token,
                wrapper->md5_fingerprint,
                parse_censorship_strategy(wrapper->censorship_strategy),
                [wrapper]() {
                    connected_callback_adapter(wrapper);
                },
                4,
                wrapper->idle_timeout_seconds
            );
        }

        if (wrapper->running && wrapper->client) {
            wrapper->client->Run();
        }
        disconnected_callback_adapter(true, "WebSocket client stopped", wrapper);
    } catch (const std::exception& ex) {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            wrapper->last_error = std::string("WebSocket wrapper exception: ") + ex.what();
            wrapper->last_disconnect_reason = wrapper->last_error;
        }
        disconnected_callback_adapter(false,
                                      std::string("WebSocket wrapper exception: ") + ex.what(),
                                      wrapper);
    } catch (...) {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            wrapper->last_error = "WebSocket wrapper unknown exception";
            wrapper->last_disconnect_reason = wrapper->last_error;
        }
        disconnected_callback_adapter(false, "WebSocket wrapper unknown exception", wrapper);
    }

    wrapper->running = false;
}
} // namespace

extern "C" {

WebsocketClientBridgePtr websocket_client_bridge_create(
    const char* server_ip,
    int server_port,
    const char* tun_ipv4,
    const char* sni,
    const char* access_token,
    const char* md5_fingerprint,
    const char* censorship_strategy,
    IPPacketCallback packet_callback,
    ConnectionCallback connected_callback,
    DisconnectedCallback disconnected_callback,
    void* context) {

    try {
        auto wrapper = new WebsocketClientWrapper(
            packet_callback,
            connected_callback,
            disconnected_callback,
            context
        );

        wrapper->server_ip = server_ip;
        wrapper->server_port = server_port;
        wrapper->tun_ipv4 = tun_ipv4;
        wrapper->sni = sni;
        wrapper->access_token = access_token;
        wrapper->md5_fingerprint = md5_fingerprint;
        wrapper->censorship_strategy = censorship_strategy ? censorship_strategy : "SNI";
        wrapper->idle_timeout_seconds = parse_int_option(
            wrapper->censorship_strategy,
            "idle_timeout",
            kDefaultIdleTimeoutSeconds
        );
        wrapper->tun_ipv6 = parse_string_option(
            wrapper->censorship_strategy,
            "tun_ipv6",
            FPTN_CLIENT_DEFAULT_ADDRESS_IP6
        );

        SPDLOG_INFO(
            "WebSocket bridge config idle_timeout={}s tun_ipv6={}",
            wrapper->idle_timeout_seconds,
            wrapper->tun_ipv6
        );

        return static_cast<WebsocketClientBridgePtr>(wrapper);
    } catch (...) {
        return nullptr;
    }
}

void websocket_client_bridge_destroy(WebsocketClientBridgePtr client) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(client);
    if (wrapper) {
        websocket_client_bridge_stop(client);
        delete wrapper;
    }
}

bool websocket_client_bridge_start(WebsocketClientBridgePtr client) {
    try {
        auto wrapper = static_cast<WebsocketClientWrapper*>(client);
        if (!wrapper || wrapper->running || wrapper->client_thread.joinable()) {
            return false;
        }

        wrapper->running = true;
        wrapper->client_thread = std::thread(client_run_thread, wrapper);
        return true;
    } catch (...) {
        return false;
    }
}

bool websocket_client_bridge_stop(WebsocketClientBridgePtr client) {
    try {
        auto wrapper = static_cast<WebsocketClientWrapper*>(client);
        if (!wrapper) {
            return false;
        }

        wrapper->running = false;

        std::shared_ptr<fptn::protocol::https::WebsocketClient> active_client;
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            active_client = wrapper->client;
            wrapper->client.reset();
        }

        if (active_client) {
            active_client->Stop();
        }

        if (wrapper->client_thread.joinable()) {
            wrapper->client_thread.join();
        }

        return active_client != nullptr;
    } catch (...) {
        return false;
    }
}

bool websocket_client_bridge_send_packet(WebsocketClientBridgePtr client,
                                         const uint8_t* packet_data,
                                         uint32_t length) {
    try {
        auto wrapper = static_cast<WebsocketClientWrapper*>(client);
        if (wrapper && wrapper->client && wrapper->running) {
            fptn::common::network::IPPacketData buffer(packet_data, packet_data + length);
            auto packet = fptn::common::network::IPPacket::Parse(std::move(buffer));
            if (packet) {
                return wrapper->client->Send(std::move(packet));
            }
            return false;
        }
    } catch (...) {
    }
    return false;
}

bool websocket_client_bridge_is_started(WebsocketClientBridgePtr client) {
    try {
        auto wrapper = static_cast<WebsocketClientWrapper*>(client);
        return wrapper && wrapper->client && wrapper->client->IsStarted();
    } catch (...) {
        return false;
    }
}

WebsocketClientBridgeStatus websocket_client_bridge_status(WebsocketClientBridgePtr client) {
    WebsocketClientBridgeStatus status = {false, false, 0, nullptr, nullptr, 0, 0, 0, 0, 0, 0, 0, false};
    try {
        auto wrapper = static_cast<WebsocketClientWrapper*>(client);
        if (!wrapper) {
            status.last_error = strdup("Invalid handle");
            return status;
        }
        std::unique_lock<std::mutex> lock(wrapper->mutex);
        status.running = wrapper->running;
        status.started = wrapper->client && wrapper->client->IsStarted();
        status.idle_timeout_seconds = wrapper->idle_timeout_seconds;
        if (!wrapper->last_error.empty()) {
            status.last_error = strdup(wrapper->last_error.c_str());
        }
        if (!wrapper->last_disconnect_reason.empty()) {
            status.last_disconnect_reason = strdup(wrapper->last_disconnect_reason.c_str());
        }
        status.memory_resident_bytes = current_resident_size_bytes();
        status.memory_phys_footprint_bytes = current_phys_footprint_bytes();
        status.received_packet_count = wrapper->received_packet_count.load();
        status.received_byte_count = wrapper->received_byte_count.load();
        status.callback_enter_count = wrapper->callback_enter_count.load();
        status.callback_exit_count = wrapper->callback_exit_count.load();
        status.callback_byte_count = wrapper->callback_byte_count.load();
        status.in_packet_callback = wrapper->in_packet_callback.load();
    } catch (const std::exception& ex) {
        status.last_error = strdup(ex.what());
    } catch (...) {
        status.last_error = strdup("Unknown error occurred");
    }
    return status;
}

void websocket_client_bridge_status_free(WebsocketClientBridgeStatus status) {
    if (status.last_error) {
        free(status.last_error);
    }
    if (status.last_disconnect_reason) {
        free(status.last_disconnect_reason);
    }
}

} // extern "C"

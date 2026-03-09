/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#include <atomic>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#include <fptn-protocol-lib/websocket/websocket_client.h>

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
    std::shared_ptr<fptn::protocol::websocket::WebsocketClient> client;
    std::thread client_thread;
    std::atomic<bool> running{false};
    std::mutex mutex;
    int idle_timeout_seconds;

    std::string server_ip;
    int server_port;
    std::string tun_ipv4;
    std::string sni;
    std::string access_token;
    std::string md5_fingerprint;
    std::string censorship_strategy;

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

namespace {
void packet_callback_adapter(fptn::common::network::IPPacketPtr packet,
                             void* user_data) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(user_data);
    if (wrapper && wrapper->packet_callback && packet) {
        const auto* raw_packet = packet->GetRawPacket();
        const auto* data = static_cast<const uint8_t*>(raw_packet->getRawData());
        const auto len = raw_packet->getRawDataLen();
        wrapper->packet_callback(data, len, wrapper->context);
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

            wrapper->client = std::make_shared<fptn::protocol::websocket::WebsocketClient>(
                fptn::common::network::IPv4Address::Create(wrapper->server_ip),
                wrapper->server_port,
                fptn::common::network::IPv4Address::Create(wrapper->tun_ipv4),
                fptn::common::network::IPv6Address::Create(FPTN_CLIENT_DEFAULT_ADDRESS_IP6),
                [wrapper](auto packet) {
                    packet_callback_adapter(std::move(packet), wrapper);
                },
                wrapper->sni,
                wrapper->access_token,
                wrapper->md5_fingerprint,
                wrapper->idle_timeout_seconds,
                [wrapper]() {
                    connected_callback_adapter(wrapper);
                },
                [wrapper](bool was_connected, const std::string& reason) {
                    disconnected_callback_adapter(was_connected, reason, wrapper);
                }
            );
        }

        if (wrapper->running && wrapper->client) {
            wrapper->client->Run();
        }
    } catch (const std::exception& ex) {
        disconnected_callback_adapter(false,
                                      std::string("WebSocket wrapper exception: ") + ex.what(),
                                      wrapper);
    } catch (...) {
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

        SPDLOG_INFO(
            "WebSocket bridge config idle_timeout={}s",
            wrapper->idle_timeout_seconds
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

        std::shared_ptr<fptn::protocol::websocket::WebsocketClient> active_client;
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
            auto packet = fptn::common::network::IPPacket::Parse(packet_data, length);
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

} // extern "C"

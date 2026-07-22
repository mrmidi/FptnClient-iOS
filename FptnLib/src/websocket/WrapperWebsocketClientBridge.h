/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#ifndef WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H
#define WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include <string>
#include <swift/bridging>

// Forward declaration of internal wrapper implementation
struct WebsocketClientWrapper;

struct WebsocketClientBridgeStatus {
    bool running;
    bool started;
    int idle_timeout_seconds;
    std::string last_error;
    std::string last_disconnect_reason;
    uint64_t memory_resident_bytes;
    uint64_t memory_phys_footprint_bytes;
    int64_t received_packet_count;
    int64_t received_byte_count;
    int64_t callback_enter_count;
    int64_t callback_exit_count;
    int64_t callback_byte_count;
    bool in_packet_callback;
    // PR1A: socket buffer diagnostics and process-wide lifecycle counters.
    int requested_rcvbuf_bytes;
    int requested_sndbuf_bytes;
    int effective_rcvbuf_bytes;
    int effective_sndbuf_bytes;
    int live_clients;
    int active_reader_coroutines;
    int active_sender_coroutines;
    int socket_buffer_set_error_count;
};

// PR0: SWIFT_NONCOPYABLE makes Swift import this as ~Copyable,
// removing the implicitly-unwrapped-optional workaround in Swift wrappers.
class SWIFT_NONCOPYABLE WebsocketSwiftBridge {
public:
    // Callbacks
    using IPPacketCallback = void (*)(const uint8_t* packet_data, uint32_t length, void* context);
    using ConnectionCallback = void (*)(void* context);
    using DisconnectedCallback = void (*)(bool was_connected, const char* reason, void* context);
    using IPAssignedCallback = void (*)(const char* ip_v4, const char* ip_v6, void* context);

    WebsocketSwiftBridge(
        const std::string& server_ip,
        int server_port,
        const std::string& tun_ipv4,
        const std::string& sni,
        const std::string& access_token,
        const std::string& md5_fingerprint,
        const std::string& censorship_strategy,
        IPPacketCallback packet_callback,
        ConnectionCallback connected_callback,
        DisconnectedCallback disconnected_callback,
        void* context
    );

    ~WebsocketSwiftBridge();

    WebsocketSwiftBridge(const WebsocketSwiftBridge&) = delete;
    WebsocketSwiftBridge& operator=(const WebsocketSwiftBridge&) = delete;
    WebsocketSwiftBridge(WebsocketSwiftBridge&& other) noexcept;
    WebsocketSwiftBridge& operator=(WebsocketSwiftBridge&& other) noexcept;

    bool start();
    bool stop();
    bool sendPacket(const uint8_t* packet_data, uint32_t length);
    bool isStarted() const;
    WebsocketClientBridgeStatus getStatus() const;
    void registerIPAssignedCallback(IPAssignedCallback callback);

private:
    WebsocketClientWrapper* wrapper_;
};

#endif // WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H

/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#ifndef WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H
#define WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque pointer to C++ WebsocketClient instance
typedef void* WebsocketClientBridgePtr;

// Callback types
typedef void (*IPPacketCallback)(const uint8_t* packet_data, uint32_t length, void* context);
typedef void (*ConnectionCallback)(void* context);
typedef void (*IPAssignedCallback)(const char* ip_v4, const char* ip_v6, void* context);
typedef void (*DisconnectedCallback)(bool was_connected, const char* reason, void* context);

typedef struct {
    bool running;
    bool started;
    int idle_timeout_seconds;
    char* last_error;
    char* last_disconnect_reason;
    uint64_t memory_resident_bytes;
    uint64_t memory_phys_footprint_bytes;
    int64_t received_packet_count;
    int64_t received_byte_count;
    int64_t callback_enter_count;
    int64_t callback_exit_count;
    int64_t callback_byte_count;
    bool in_packet_callback;
} WebsocketClientBridgeStatus;

// Creates new websocket client instance
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
    void* context);

// Destroys websocket client instance
void websocket_client_bridge_destroy(WebsocketClientBridgePtr client);

// Starts websocket client connection
bool websocket_client_bridge_start(WebsocketClientBridgePtr client);

// Stops websocket client connection
bool websocket_client_bridge_stop(WebsocketClientBridgePtr client);

// Sends IP packet through websocket
bool websocket_client_bridge_send_packet(WebsocketClientBridgePtr client,
                                        const uint8_t* packet_data,
                                        uint32_t length);

// Checks if websocket client is started
bool websocket_client_bridge_is_started(WebsocketClientBridgePtr client);
WebsocketClientBridgeStatus websocket_client_bridge_status(WebsocketClientBridgePtr client);
void websocket_client_bridge_status_free(WebsocketClientBridgeStatus status);
void websocket_client_bridge_register_ip_assigned_callback(WebsocketClientBridgePtr client, IPAssignedCallback callback);

#ifdef __cplusplus
}
#endif

#endif // WRAPPER_WEBSOCKET_CLIENT_BRIDGE_H

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
#include <TargetConditionals.h>

#include <fptn-protocol-lib/https/websocket_client/websocket_client.h>

#ifndef FPTN_VERSION
#define FPTN_VERSION "unknown"
#endif

#include "common/logger/logger.h"
#include "WrapperWebsocketClientBridge.h"
#include "../apple/FPTNAppleLogSink.h"

#ifndef FPTN_CLIENT_DEFAULT_ADDRESS_IP6
#define FPTN_CLIENT_DEFAULT_ADDRESS_IP6 "fd00::1"
#endif

constexpr const int kDefaultIdleTimeoutSeconds = 60;

struct WebsocketClientWrapper {
    struct CopyCounters {
        std::atomic<uint64_t> inbound_zero_copy_packets{0};
        std::atomic<uint64_t> inbound_zero_copy_bytes{0};
        std::atomic<uint64_t> inbound_batches_delivered{0};
    };
    WebsocketSwiftBridge::IPPacketBatchCallback packet_callback;
    WebsocketSwiftBridge::ConnectionCallback connected_callback;
    WebsocketSwiftBridge::DisconnectedCallback disconnected_callback;
    WebsocketSwiftBridge::IPAssignedCallback ip_assigned_callback;
    void* context;
    std::shared_ptr<fptn::protocol::https::WebsocketClient> client;
    std::thread client_thread;
    std::atomic<bool> running{false};
    std::mutex mutex;
    int idle_timeout_seconds;
    // PR1C: terminal reason stored after Run() returns.
    std::uint32_t final_terminal_reason{0};
    fptn::protocol::https::PacketCopyCounters final_copy_counters{};

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
    std::shared_ptr<CopyCounters> copy_counters{std::make_shared<CopyCounters>()};

    WebsocketClientWrapper(
        WebsocketSwiftBridge::IPPacketBatchCallback p_callback,
        WebsocketSwiftBridge::ConnectionCallback c_callback,
        WebsocketSwiftBridge::DisconnectedCallback d_callback,
        void* ctx
    )
        : packet_callback(p_callback),
          connected_callback(c_callback),
          disconnected_callback(d_callback),
          ip_assigned_callback(nullptr),
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
        return CensorshipStrategy::kSniRealityModeYandex26_4;
    }
    if (strategy == "yandex25" || strategy == "sni_reality_yandex25" ||
        strategy == "sni-reality-yandex25") {
        return CensorshipStrategy::kSniRealityModeYandex25;
    }
    if (strategy == "yandex24" || strategy == "sni_reality_yandex24" ||
        std::string(strategy) == "sni-reality-yandex24") {
        return CensorshipStrategy::kSniRealityModeYandex24;
    }
    if (strategy == "safari26" || strategy == "sni_reality_safari26" ||
        strategy == "sni-reality-safari26") {
        return CensorshipStrategy::kSniRealityModeSafari26_5;
    }
    return CensorshipStrategy::kSni;
}

std::atomic<uint64_t> g_live_packet_leases{0};
std::atomic<uint64_t> g_peak_packet_leases{0};
// PR6: byte-accurate companion to the lease count. Feeds RunReader's inbound
// backpressure watermark and getStatus() reporting.
std::atomic<uint64_t> g_live_lease_bytes{0};
std::atomic<uint64_t> g_peak_lease_bytes{0};

extern "C" void fptn_release_owned_packet(void* owner) noexcept {
    auto* packet = static_cast<fptn::common::network::IPPacket*>(owner);
    if (packet) {
        g_live_lease_bytes.fetch_sub(packet->Data().size(), std::memory_order_relaxed);
    }
    delete packet;
    g_live_packet_leases.fetch_sub(1, std::memory_order_relaxed);
}

void packet_callback_adapter(fptn::common::network::BatchIPPacketPtr packets,
                             void* user_data) {
    auto wrapper = static_cast<WebsocketClientWrapper*>(user_data);
    if (wrapper && wrapper->packet_callback && !packets.empty()) {
        // Keep every packet under RAII ownership until all descriptor
        // allocations have succeeded. This makes an exception during batch
        // construction leak-free without a per-packet lease wrapper.
        fptn::common::network::BatchIPPacketPtr leases;
        leases.reserve(packets.size());
        std::vector<FptnOwnedPacketDescriptor> descriptors;
        descriptors.reserve(packets.size());
        std::uint64_t bytes = 0;
        for (auto& packet : packets) {
            if (!packet || packet->Data().empty()) continue;
            leases.push_back(std::move(packet));
            const auto& data = leases.back()->Data();
            descriptors.push_back({
                const_cast<std::uint8_t*>(data.data()),
                static_cast<std::uint32_t>(data.size()),
                static_cast<std::uint8_t>(leases.back()->IsIPv6() ? 6 : 4),
                leases.back().get()
            });
            bytes += data.size();
        }
        if (descriptors.empty()) return;
        auto& counters = *wrapper->copy_counters;
        counters.inbound_zero_copy_packets.fetch_add(descriptors.size(), std::memory_order_relaxed);
        counters.inbound_zero_copy_bytes.fetch_add(bytes, std::memory_order_relaxed);
        counters.inbound_batches_delivered.fetch_add(1, std::memory_order_relaxed);
        const auto live = g_live_packet_leases.fetch_add(descriptors.size(), std::memory_order_relaxed) + descriptors.size();
        auto peak = g_peak_packet_leases.load(std::memory_order_relaxed);
        while (live > peak && !g_peak_packet_leases.compare_exchange_weak(peak, live, std::memory_order_relaxed)) {}
        const auto live_bytes = g_live_lease_bytes.fetch_add(bytes, std::memory_order_relaxed) + bytes;
        auto peak_bytes = g_peak_lease_bytes.load(std::memory_order_relaxed);
        while (live_bytes > peak_bytes && !g_peak_lease_bytes.compare_exchange_weak(peak_bytes, live_bytes, std::memory_order_relaxed)) {}
        wrapper->received_packet_count.fetch_add(descriptors.size());
        wrapper->received_byte_count.fetch_add(bytes);
        wrapper->callback_enter_count.fetch_add(1);
        wrapper->callback_byte_count.fetch_add(bytes);
        wrapper->in_packet_callback = true;
        // PR1A: removed SPDLOG_WARN + two Mach task_info syscalls that
        // fired on packet #1 and every 500th packet. These added
        // non-trivial per-batch overhead on the receive hot path.
        // Counters above remain for getStatus() reporting.
        for (auto& lease : leases) {
            lease.release();
        }
        wrapper->packet_callback(descriptors.data(),
                                 static_cast<uint32_t>(descriptors.size()),
                                 wrapper->context);
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

    // PR1C: keep a local strong pointer for the entire thread lifetime.
    // The wrapper's stop() may reset wrapper->client before join, but
    // this local keeps the client alive until Run() returns and we've
    // read the terminal reason.
    std::shared_ptr<fptn::protocol::https::WebsocketClient> client;

    try {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            if (!wrapper->running) {
                return;
            }

            fptn::protocol::https::WebsocketClient::Config client_config;
            client_config.server_ip = fptn::common::network::IPv4Address::Create(wrapper->server_ip);
            client_config.server_port = wrapper->server_port;
            client_config.tun_interface_address_ipv4 = fptn::common::network::IPv4Address::Create(wrapper->tun_ipv4);
            client_config.tun_interface_address_ipv6 = fptn::common::network::IPv6Address::Create(wrapper->tun_ipv6);
            client_config.sni = wrapper->sni;
            client_config.access_token = wrapper->access_token;
            client_config.expected_md5_fingerprint = wrapper->md5_fingerprint;
            client_config.censorship_strategy = parse_censorship_strategy(wrapper->censorship_strategy);
            client_config.on_connected_callback = [wrapper]() {
                connected_callback_adapter(wrapper);
            };
            client_config.new_ip_pkt_batch_callback = [wrapper](auto packets) {
                packet_callback_adapter(std::move(packets), wrapper);
            };
            // PR6: feed the reader's inbound backpressure gate with the current
            // leased-but-undrained byte count (process-wide, matching the lease
            // gauges above).
            client_config.inbound_inflight_bytes = []() -> std::size_t {
                return static_cast<std::size_t>(
                    g_live_lease_bytes.load(std::memory_order_relaxed));
            };

            client = std::make_shared<fptn::protocol::https::WebsocketClient>(
                std::move(client_config),
#if defined(__APPLE__) && TARGET_OS_IOS
                1
#else
                4
#endif
            );
            wrapper->client = client;
        }

        // PR1C: always drive the client once constructed. A pre-Run
        // stop is represented by stop_requested_; Run() processes the
        // posted cleanup and exits through the barrier. Skipping Run()
        // would leave the posted lambda (and its captured shared_ptr)
        // stranded in the io_context forever.
        if (client) {
            client->Run();
        }

        const auto reason = client ? client->GetTerminalReason() : 0;
        const auto copy_counters = client
            ? client->GetPacketCopyCounters()
            : fptn::protocol::https::PacketCopyCounters{};
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            if (wrapper->client == client) {
                wrapper->client.reset();
            }
            wrapper->final_terminal_reason = reason;
            wrapper->final_copy_counters = copy_counters;
        }
        disconnected_callback_adapter(true, "WebSocket client stopped", wrapper);
    } catch (const std::exception& ex) {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            wrapper->last_error = std::string("WebSocket wrapper exception: ") + ex.what();
            wrapper->last_disconnect_reason = wrapper->last_error;
            if (wrapper->client == client) {
                wrapper->client.reset();
            }
        }
        disconnected_callback_adapter(false,
                                      std::string("WebSocket wrapper exception: ") + ex.what(),
                                      wrapper);
    } catch (...) {
        {
            std::unique_lock<std::mutex> lock(wrapper->mutex);
            wrapper->last_error = "WebSocket wrapper unknown exception";
            wrapper->last_disconnect_reason = wrapper->last_error;
            if (wrapper->client == client) {
                wrapper->client.reset();
            }
        }
        disconnected_callback_adapter(false, "WebSocket wrapper unknown exception", wrapper);
    }

    wrapper->running = false;
}
} // namespace

WebsocketSwiftBridge::WebsocketSwiftBridge(
    const std::string& server_ip,
    int server_port,
    const std::string& tun_ipv4,
    const std::string& sni,
    const std::string& access_token,
    const std::string& md5_fingerprint,
    const std::string& censorship_strategy,
    IPPacketBatchCallback packet_callback,
    ConnectionCallback connected_callback,
    DisconnectedCallback disconnected_callback,
    void* context
) {
    FPTNInstallAppleLogSink();
    wrapper_ = new WebsocketClientWrapper(
        packet_callback,
        connected_callback,
        disconnected_callback,
        context
    );

    wrapper_->server_ip = server_ip;
    wrapper_->server_port = server_port;
    wrapper_->tun_ipv4 = tun_ipv4;
    wrapper_->sni = sni;
    wrapper_->access_token = access_token;
    wrapper_->md5_fingerprint = md5_fingerprint;
    wrapper_->censorship_strategy = censorship_strategy.empty() ? "SNI" : censorship_strategy;
    wrapper_->idle_timeout_seconds = parse_int_option(
        wrapper_->censorship_strategy,
        "idle_timeout",
        kDefaultIdleTimeoutSeconds
    );
    wrapper_->tun_ipv6 = parse_string_option(
        wrapper_->censorship_strategy,
        "tun_ipv6",
        FPTN_CLIENT_DEFAULT_ADDRESS_IP6
    );

    SPDLOG_INFO(
        "WebSocket bridge config idle_timeout={}s tun_ipv6={}",
        wrapper_->idle_timeout_seconds,
        wrapper_->tun_ipv6
    );
}

WebsocketSwiftBridge::~WebsocketSwiftBridge() {
    if (wrapper_) {
        stop();
        delete wrapper_;
        wrapper_ = nullptr;
    }
}

WebsocketSwiftBridge::WebsocketSwiftBridge(WebsocketSwiftBridge&& other) noexcept : wrapper_(other.wrapper_) {
    other.wrapper_ = nullptr;
}

WebsocketSwiftBridge& WebsocketSwiftBridge::operator=(WebsocketSwiftBridge&& other) noexcept {
    if (this != &other) {
        if (wrapper_) {
            stop();
            delete wrapper_;
        }
        wrapper_ = other.wrapper_;
        other.wrapper_ = nullptr;
    }
    return *this;
}

bool WebsocketSwiftBridge::start() {
    if (!wrapper_ || wrapper_->running || wrapper_->client_thread.joinable()) {
        return false;
    }

    try {
        wrapper_->running = true;
        wrapper_->client_thread = std::thread(client_run_thread, wrapper_);
        return true;
    } catch (...) {
        wrapper_->running = false;
        return false;
    }
}

// PR1C: stop accepts an origin so the caller can distinguish
// tunnel shutdown, reconnect, and bridge destruction.
bool WebsocketSwiftBridge::stop(std::uint16_t origin) {
    if (!wrapper_) {
        return false;
    }

    wrapper_->running = false;

    std::shared_ptr<fptn::protocol::https::WebsocketClient> active_client;
    {
        std::unique_lock<std::mutex> lock(wrapper_->mutex);
        active_client = wrapper_->client;
        wrapper_->client.reset();
    }

    if (active_client) {
        active_client->Stop(static_cast<fptn::protocol::https::StopOrigin>(origin));
    }

    if (wrapper_->client_thread.joinable()) {
        wrapper_->client_thread.join();
    }

    return active_client != nullptr;
}

// PR1B: returns typed send result as uint8_t.
// 0=accepted, 1=queue_full, 2=transport_stopped, 3=invalid_packet.
std::uintptr_t WebsocketSwiftBridge::splitTransportHandle() {
    return reinterpret_cast<std::uintptr_t>(this);
}

std::shared_ptr<fptn::protocol::https::WebsocketClient>
WebsocketSwiftBridge::splitRoutingTransport() const {
    if (!wrapper_) {
        return nullptr;
    }
    // Same pattern as sendPacket: copy under the mutex so this cannot race
    // stop() resetting wrapper_->client.
    std::lock_guard<std::mutex> lock(wrapper_->mutex);
    return wrapper_->client;
}

// PR1C: takes a local copy of the client under the mutex to avoid
// racing with stop() resetting wrapper_->client.
std::uint8_t WebsocketSwiftBridge::sendPacket(const uint8_t* packet_data, uint32_t length) {
    if (!wrapper_ || !wrapper_->running) {
        return static_cast<std::uint8_t>(fptn::protocol::https::SendResult::transport_stopped);
    }
    if (!packet_data || length == 0) {
        return static_cast<std::uint8_t>(fptn::protocol::https::SendResult::invalid_packet);
    }
    std::shared_ptr<fptn::protocol::https::WebsocketClient> client;
    {
        std::lock_guard<std::mutex> lock(wrapper_->mutex);
        client = wrapper_->client;
    }
    if (!client) {
        return static_cast<std::uint8_t>(fptn::protocol::https::SendResult::transport_stopped);
    }
    try {
        return static_cast<std::uint8_t>(client->TrySendPacketBytes(packet_data, length));
    } catch (...) {
        return static_cast<std::uint8_t>(fptn::protocol::https::SendResult::invalid_packet);
    }
}

bool WebsocketSwiftBridge::isStarted() const {
    if (!wrapper_) return false;
    std::shared_ptr<fptn::protocol::https::WebsocketClient> client;
    {
        std::lock_guard<std::mutex> lock(wrapper_->mutex);
        client = wrapper_->client;
    }
    return client && client->IsStarted();
}

WebsocketClientBridgeStatus WebsocketSwiftBridge::getStatus() const {
    WebsocketClientBridgeStatus status = {};
    if (!wrapper_) {
        status.last_error = "Invalid handle";
        return status;
    }
    try {
        std::unique_lock<std::mutex> lock(wrapper_->mutex);
        status.running = wrapper_->running;
        status.started = wrapper_->client && wrapper_->client->IsStarted();
        status.idle_timeout_seconds = wrapper_->idle_timeout_seconds;
        status.last_error = wrapper_->last_error;
        status.last_disconnect_reason = wrapper_->last_disconnect_reason;
        status.memory_resident_bytes = current_resident_size_bytes();
        status.memory_phys_footprint_bytes = current_phys_footprint_bytes();
        status.received_packet_count = wrapper_->received_packet_count.load();
        status.received_byte_count = wrapper_->received_byte_count.load();
        status.callback_enter_count = wrapper_->callback_enter_count.load();
        status.callback_exit_count = wrapper_->callback_exit_count.load();
        status.callback_byte_count = wrapper_->callback_byte_count.load();
        status.in_packet_callback = wrapper_->in_packet_callback.load();
        // PR1A: socket buffer diagnostics and process-wide lifecycle counters.
        if (wrapper_->client) {
            status.requested_rcvbuf_bytes = wrapper_->client->GetRequestedRcvbufBytes();
            status.requested_sndbuf_bytes = wrapper_->client->GetRequestedSndbufBytes();
            status.effective_rcvbuf_bytes = wrapper_->client->GetEffectiveRcvbufBytes();
            status.effective_sndbuf_bytes = wrapper_->client->GetEffectiveSndbufBytes();
            status.socket_buffer_set_error_count = wrapper_->client->GetSocketBufferSetErrorCount();
            status.queued_packets = wrapper_->client->GetQueuedPackets();
            status.queued_bytes = wrapper_->client->GetQueuedBytes();
            status.queued_bytes_peak = wrapper_->client->GetQueuedBytesPeak();
            status.queue_full_count = wrapper_->client->GetQueueFullCount();
            const auto reason = wrapper_->client->GetTerminalReason();
            status.disconnect_code = static_cast<uint16_t>(fptn::protocol::https::unpackDisconnectCode(reason));
            status.stop_origin = static_cast<uint16_t>(fptn::protocol::https::unpackStopOrigin(reason));
            status.stop_cleanup_completed = wrapper_->client->IsStopCleanupCompleted();
            status.active_operations = wrapper_->client->GetActiveOperations();
        } else {
            // PR1C: client was reset (after stop); use stored terminal reason.
            const auto reason = wrapper_->final_terminal_reason;
            status.disconnect_code = static_cast<uint16_t>(fptn::protocol::https::unpackDisconnectCode(reason));
            status.stop_origin = static_cast<uint16_t>(fptn::protocol::https::unpackStopOrigin(reason));
            status.stop_cleanup_completed = true;
            status.active_operations = 0;
        }
        status.live_clients = fptn::protocol::https::WebsocketClient::GetLiveClients();
        status.active_reader_coroutines = fptn::protocol::https::WebsocketClient::GetActiveReaderCoroutines();
        status.active_sender_coroutines = fptn::protocol::https::WebsocketClient::GetActiveSenderCoroutines();
        const auto native_copy_counters = wrapper_->client
            ? wrapper_->client->GetPacketCopyCounters()
            : wrapper_->final_copy_counters;
        const auto& counters = *wrapper_->copy_counters;
        status.outbound_admission_copy_operations = native_copy_counters.outbound_admission_copy_operations;
        status.outbound_admission_copy_bytes = native_copy_counters.outbound_admission_copy_bytes;
        status.outbound_rejected_before_copy_packets = native_copy_counters.outbound_rejected_before_copy_packets;
        status.outbound_rejected_before_copy_bytes = native_copy_counters.outbound_rejected_before_copy_bytes;
        status.outbound_copied_but_rejected_packets = native_copy_counters.outbound_copied_but_rejected_packets;
        status.outbound_copied_but_rejected_bytes = native_copy_counters.outbound_copied_but_rejected_bytes;
        status.inbound_zero_copy_packets = counters.inbound_zero_copy_packets.load(std::memory_order_relaxed);
        status.inbound_zero_copy_bytes = counters.inbound_zero_copy_bytes.load(std::memory_order_relaxed);
        status.inbound_batches_delivered = counters.inbound_batches_delivered.load(std::memory_order_relaxed);
        status.live_packet_leases = g_live_packet_leases.load(std::memory_order_relaxed);
        status.peak_packet_leases = g_peak_packet_leases.load(std::memory_order_relaxed);
        status.live_lease_bytes = g_live_lease_bytes.load(std::memory_order_relaxed);
        status.peak_lease_bytes = g_peak_lease_bytes.load(std::memory_order_relaxed);
    } catch (const std::exception& ex) {
        status.last_error = ex.what();
    } catch (...) {
        status.last_error = "Unknown error occurred";
    }
    return status;
}

void WebsocketSwiftBridge::registerIPAssignedCallback(IPAssignedCallback callback) {
    (void)callback;
}

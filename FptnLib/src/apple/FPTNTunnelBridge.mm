/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import "FPTNTunnelBridge.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "fptn-protocol-lib/tunnel/tunnel_engine.h"
#include "../websocket/WrapperWebsocketClientBridge.h"
#include "FPTNAppleLogSink.h"

namespace {

// The provider replaces its websocket bridge on every reconnect generation, so
// the transport is resolved through this slot on each batch rather than
// captured once. The mutex is held across the resolve so a setter cannot drop
// the old bridge while an ingress call is still inside it.
struct SplitTransportSlot {
    std::mutex mutex;
    WebsocketSwiftBridge* bridge = nullptr;
};

std::vector<std::string> ToStringVector(NSArray<NSString *> *values) {
    std::vector<std::string> out;
    out.reserve(values.count);
    for (NSString *value in values) {
        if (value.length > 0) {
            out.emplace_back([value UTF8String]);
        }
    }
    return out;
}

}  // namespace

@interface FPTNTunnelBridge () {
    std::unique_ptr<fptn::tunnel::TunnelEngine> _engine;
    FPTNApplePacketFlowAdapter * __weak _egressAdapter;
    std::shared_ptr<SplitTransportSlot> _transportSlot;
}
@end

@implementation FPTNTunnelBridge

+ (void)initialize {
    if (self == [FPTNTunnelBridge class]) {
        // Before any native code runs, so nothing is logged into the void.
        FPTNInstallAppleLogSink();
    }
}

+ (BOOL)isFlowSupported {
    return [FPTNApplePacketFlowAdapter isFlowSupported];
}

- (instancetype)initWithTunIPv4:(NSString *)tunIPv4
                        tunIPv6:(nullable NSString *)tunIPv6
                            mtu:(uint16_t)mtu {
    self = [super init];
    if (self) {
        fptn::tunnel::TunnelConfiguration config;
        config.mode = fptn::tunnel::DataPlaneMode::flow_proxy;
        config.flow.tun_ipv4 = tunIPv4 ? [tunIPv4 UTF8String] : "";
        config.flow.tun_ipv6 = tunIPv6 ? [tunIPv6 UTF8String] : "";
        config.flow.mtu = mtu;

        __weak __typeof__(self) weakSelf = self;
        fptn::tunnel::TunnelCallbacks callbacks;
        callbacks.on_owned_packet_batch = [weakSelf](fptn::tunnel::OwnedPacketBatchView batch) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            FPTNApplePacketFlowAdapter *adapter = strongSelf->_egressAdapter;
            if (adapter) {
                [adapter sendEgressBatch:batch];
            }
        };

        auto createResult = fptn::tunnel::TunnelEngine::Create(config, std::move(callbacks));
        if (createResult.has_value()) {
            _engine = std::move(*createResult);
        }
    }
    return self;
}

- (nullable instancetype)initSplitWithTunIPv4:(NSString *)tunIPv4
                                      tunIPv6:(nullable NSString *)tunIPv6
                                          mtu:(uint16_t)mtu
                                     serverIP:(NSString *)serverIP
                                   serverPort:(int)serverPort
                               directDomains:(NSArray<NSString *> *)directDomains
                               rejectDomains:(NSArray<NSString *> *)rejectDomains
                                 dropDomains:(NSArray<NSString *> *)dropDomains
                             tunnelResolvers:(NSArray<NSString *> *)tunnelResolvers {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (serverIP.length == 0 || serverPort <= 0) {
        return nil;
    }
    _transportSlot = std::make_shared<SplitTransportSlot>();

    fptn::tunnel::TunnelConfiguration config;
    config.mode = fptn::tunnel::DataPlaneMode::split;
    config.flow.tun_ipv4 = tunIPv4 ? [tunIPv4 UTF8String] : "";
    config.flow.tun_ipv6 = tunIPv6 ? [tunIPv6 UTF8String] : "";
    config.flow.mtu = mtu;
    // The lwIP netif uses the configured tun address, not the server-assigned
    // one: the transport NATs between them on the wire, so the assigned
    // address never appears on this interface.
    config.l3.server_ip = [serverIP UTF8String];
    config.l3.server_port = serverPort;
    config.l3.tun_ipv4 = config.flow.tun_ipv4;
    config.l3.tun_ipv6 = config.flow.tun_ipv6;
    config.routing.direct_domains = ToStringVector(directDomains);
    config.routing.reject_domains = ToStringVector(rejectDomains);
    config.routing.drop_domains = ToStringVector(dropDomains);
    config.routing.tunnel_resolvers = ToStringVector(tunnelResolvers);

    __weak __typeof__(self) weakSelf = self;
    fptn::tunnel::TunnelCallbacks callbacks;
    callbacks.on_owned_packet_batch = [weakSelf](fptn::tunnel::OwnedPacketBatchView batch) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        FPTNApplePacketFlowAdapter *adapter = strongSelf->_egressAdapter;
        if (adapter) {
            [adapter sendEgressBatch:batch];
        }
    };

    // Borrowed, not owned: the provider keeps managing this websocket, so a
    // reconnect swaps the transport underneath us without disturbing lwIP.
    // Resolving through the slot (rather than capturing a bridge) is what makes
    // that safe, since the provider builds a new bridge per generation.
    fptn::tunnel::TransportProvider transport =
        [slot = _transportSlot]() -> std::shared_ptr<fptn::protocol::https::WebsocketClient> {
            std::lock_guard<std::mutex> lock(slot->mutex);
            return slot->bridge ? slot->bridge->splitRoutingTransport() : nullptr;
        };

    auto createResult = fptn::tunnel::TunnelEngine::CreateSplit(
        std::move(config), std::move(callbacks), std::move(transport));
    if (!createResult.has_value()) {
        return nil;
    }
    _engine = std::move(*createResult);
    return self;
}

- (void)setSplitTransport:(nullable void *)websocketBridge {
    if (!_transportSlot) {
        return;
    }
    std::lock_guard<std::mutex> lock(_transportSlot->mutex);
    _transportSlot->bridge = static_cast<WebsocketSwiftBridge *>(websocketBridge);
}

- (void)observeInboundPacket:(const uint8_t *)bytes length:(size_t)length {
    if (!_engine || bytes == nullptr || length == 0) {
        return;
    }
    if (auto *plane = _engine->SplitPlane()) {
        plane->ObserveInboundPacket(bytes, length);
    }
}

- (void)setEgressAdapter:(nullable FPTNApplePacketFlowAdapter *)adapter {
    _egressAdapter = adapter;
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    if (!_engine) {
        if (error) {
            *error = [NSError errorWithDomain:@"net.mrmidi.FptnVPN"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create TunnelEngine"}];
        }
        return NO;
    }
    auto result = _engine->Start();
    if (!result.has_value()) {
        if (error) {
            *error = [NSError errorWithDomain:@"net.mrmidi.FptnVPN"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Engine failed to start"}];
        }
        return NO;
    }
    return YES;
}

- (void)stop {
    if (_engine) {
        _engine->Stop();
    }
}

- (BOOL)isStarted {
    return _engine != nullptr && _engine->IsStarted();
}

- (FPTNFlowCounters)flowCounters {
    FPTNFlowCounters out = {};
    if (!_engine) {
        return out;
    }
    const fptn::tunnel::FlowCounters c = _engine->Counters();
    out.inputPackets = c.input_packets;
    out.inputBytes = c.input_bytes;
    out.ingressZeroCopyPackets = c.ingress_zero_copy_packets;
    out.ingressCopyPackets = c.ingress_copy_packets;
    out.leasePoolExhaustions = c.lease_pool_exhaustions;
    out.droppedPackets = c.dropped_packets;
    out.activeTcpFlows = c.active_tcp_flows;
    out.peakTcpFlows = c.peak_tcp_flows;
    out.activeUdpFlows = c.active_udp_flows;
    out.peakUdpFlows = c.peak_udp_flows;
    out.tcpBackpressureEvents = c.tcp_backpressure_events;
    out.tcpResets = c.tcp_resets;
    out.udpDrops = c.udp_drops;
    out.tcpOutboundActive = c.tcp_outbound_active;
    out.tcpOutboundOpenedTotal = c.tcp_outbound_opened_total;
    out.udpOutboundActive = c.udp_outbound_active;
    out.outputPackets = c.output_packets;
    out.outputBytes = c.output_bytes;
    out.egressBatches = c.egress_batches;
    return out;
}

- (FPTNPacketInputResult)consumePackets:(const FPTNPacketDescriptor *)packets count:(NSUInteger)count {
    if (!_engine || count == 0) {
        return FPTNPacketInputResultInvalidPacket;
    }
    std::vector<fptn::tunnel::PacketLease> leases;
    leases.reserve(count);
    for (NSUInteger i = 0; i < count; ++i) {
        leases.push_back(fptn::tunnel::PacketLease{
            .bytes = packets[i].bytes,
            .length = packets[i].length,
            .ip_version = packets[i].ipVersion,
            // Carries the retained NSData through to the engine, which
            // releases it once the bytes are no longer referenced by a pbuf.
            .owner = packets[i].owner,
            .release = &fptn_release_ingress_packet
        });
    }
    fptn::tunnel::PacketBatchView view(leases.data(), count);
    fptn::tunnel::PacketInputResult result = _engine->InputPackets(view);
    return static_cast<FPTNPacketInputResult>(result);
}

@end

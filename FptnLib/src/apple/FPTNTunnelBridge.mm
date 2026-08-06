/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import "FPTNTunnelBridge.h"

#include <memory>
#include <vector>
#include "fptn-protocol-lib/tunnel/tunnel_engine.h"

@interface FPTNTunnelBridge () {
    std::unique_ptr<fptn::tunnel::TunnelEngine> _engine;
    FPTNApplePacketFlowAdapter * __weak _egressAdapter;
}
@end

@implementation FPTNTunnelBridge

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
        callbacks.on_owned_packet_batch = [weakSelf](fptn::tunnel::OwnedPacketBatch batch) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            FPTNApplePacketFlowAdapter *adapter = strongSelf->_egressAdapter;
            if (adapter) {
                [adapter sendEgressBatch:std::move(batch)];
            }
        };

        auto createResult = fptn::tunnel::TunnelEngine::Create(config, std::move(callbacks));
        if (createResult.has_value()) {
            _engine = std::move(*createResult);
        }
    }
    return self;
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
            .owner = nullptr,
            .release = nullptr
        });
    }
    fptn::tunnel::PacketBatchView view(leases.data(), count);
    fptn::tunnel::PacketInputResult result = _engine->InputPackets(view);
    return static_cast<FPTNPacketInputResult>(result);
}

@end

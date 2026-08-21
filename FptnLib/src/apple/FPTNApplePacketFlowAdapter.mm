/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import "FPTNApplePacketFlowAdapter.h"
#include <sys/socket.h>
#include <atomic>
#include <vector>
#include "fptn-protocol-lib/tunnel/flow_types.h"

void fptn_release_native_packet(void * _Nullable owner) noexcept {
    if (owner != nullptr) {
        delete static_cast<fptn::tunnel::OwnedBuffer*>(owner);
    }
}

void fptn_release_ingress_packet(void * _Nullable owner) noexcept {
    // Balances the CFBridgingRetain taken when the descriptor was built.
    if (owner != nullptr) {
        CFRelease(static_cast<CFTypeRef>(owner));
    }
}

@interface FPTNReadGenerationToken : NSObject
@property (nonatomic, readonly) uint64_t generation;
- (instancetype)initWithGeneration:(uint64_t)generation;
@end

@implementation FPTNReadGenerationToken
- (instancetype)initWithGeneration:(uint64_t)generation {
    self = [super init];
    if (self) {
        _generation = generation;
    }
    return self;
}
@end

@interface FPTNApplePacketFlowAdapter () {
    id<FPTNPacketFlowIO> _packetFlow;
    id<FPTNPacketBatchConsumer> __weak _consumer;
    std::atomic<bool> _running;
    std::atomic<uint64_t> _generation;
    NSNumber *_v4ProtocolNumber;
    NSNumber *_v6ProtocolNumber;

    std::atomic<uint64_t> _totalReadPackets;
    std::atomic<uint64_t> _totalReadBytes;
    std::atomic<uint64_t> _totalWritePackets;
    std::atomic<uint64_t> _totalWriteBytes;
    std::atomic<uint64_t> _staleReadCallbacks;
    std::atomic<uint64_t> _writeFailures;
    // Reused across reads instead of allocated per batch. The read callback
    // reissues itself and never overlaps, so a single buffer is safe; capacity
    // settles at the high-water batch size and stops allocating.
    std::vector<FPTNPacketDescriptor> _descriptors;
}
@end

@implementation FPTNApplePacketFlowAdapter

+ (BOOL)isFlowSupported {
#ifdef FPTN_HAS_LWIP
    return YES;
#else
    return NO;
#endif
}

- (instancetype)initWithPacketFlow:(id<FPTNPacketFlowIO>)packetFlow
                          consumer:(id<FPTNPacketBatchConsumer>)consumer {
    self = [super init];
    if (self) {
        _packetFlow = packetFlow;
        _consumer = consumer;
        _running.store(false);
        _generation.store(0);
        _v4ProtocolNumber = @(AF_INET);
        _v6ProtocolNumber = @(AF_INET6);
        _totalReadPackets.store(0);
        _totalReadBytes.store(0);
        _totalWritePackets.store(0);
        _totalWriteBytes.store(0);
        _staleReadCallbacks.store(0);
        _writeFailures.store(0);
    }
    return self;
}

- (void)start {
    bool expected = false;
    if (!_running.compare_exchange_strong(expected, true)) {
        return;
    }
    uint64_t nextGen = _generation.fetch_add(1) + 1;
    FPTNReadGenerationToken *token = [[FPTNReadGenerationToken alloc] initWithGeneration:nextGen];
    [self issueNextReadWithToken:token];
}

- (void)stop {
    bool expected = true;
    if (!_running.compare_exchange_strong(expected, false)) {
        return;
    }
    _generation.fetch_add(1);
    _consumer = nil;
}

- (void)issueNextReadWithToken:(FPTNReadGenerationToken *)token {
    if (!_running.load(std::memory_order_relaxed)) {
        return;
    }
    uint64_t currentGen = token.generation;
    __weak __typeof__(self) weakSelf = self;
    [_packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> * _Nonnull packets, NSArray<NSNumber *> * _Nonnull protocols) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (!strongSelf->_running.load(std::memory_order_relaxed) ||
            strongSelf->_generation.load(std::memory_order_relaxed) != currentGen) {
            strongSelf->_staleReadCallbacks.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        NSUInteger count = packets.count;
        if (count > 0) {
            id<FPTNPacketBatchConsumer> consumer = strongSelf->_consumer;
            if (consumer) {
                std::vector<FPTNPacketDescriptor> &descriptors = strongSelf->_descriptors;
                descriptors.assign(count, FPTNPacketDescriptor{});
                uint64_t batchBytes = 0;
                for (NSUInteger i = 0; i < count; ++i) {
                    NSData *data = packets[i];
                    uint8_t ipVer = 4;
                    if (i < protocols.count) {
                        uint8_t protoVal = [protocols[i] unsignedCharValue];
                        if (protoVal == AF_INET6) {
                            ipVer = 6;
                        }
                    }
                    descriptors[i] = FPTNPacketDescriptor{
                        .bytes = (const uint8_t *)data.bytes,
                        .length = (uint32_t)data.length,
                        .ipVersion = ipVer,
                        // NE owns these NSData only for the duration of this
                        // block; the engine reads them later on its runtime
                        // thread, so each one is retained for the engine.
                        .owner = (void *)CFBridgingRetain(data)
                    };
                    batchBytes += data.length;
                }
                FPTNPacketInputResult result = [consumer consumePackets:descriptors.data() count:count];
                if (result == FPTNPacketInputResultAccepted) {
                    strongSelf->_totalReadPackets.fetch_add(count, std::memory_order_relaxed);
                    strongSelf->_totalReadBytes.fetch_add(batchBytes, std::memory_order_relaxed);
                } else {
                    // Not accepted: ownership never transferred, so the batch
                    // is ours to release.
                    for (const auto &descriptor : descriptors) {
                        fptn_release_ingress_packet(descriptor.owner);
                    }
                }
            }
        }

        if (strongSelf->_running.load(std::memory_order_relaxed) &&
            strongSelf->_generation.load(std::memory_order_relaxed) == currentGen) {
            [strongSelf issueNextReadWithToken:token];
        }
    }];
}

- (void)sendEgressBatch:(fptn::tunnel::OwnedPacketBatchView)batch {
    if (batch.empty()) {
        return;
    }
    // Runs on the engine's executor thread, which is a plain std::thread with
    // no run loop and therefore no ambient autorelease pool. Anything the
    // Foundation/NetworkExtension code below autoreleases would otherwise
    // accumulate for the lifetime of the tunnel, and each pooled array pins
    // every packet buffer it holds.
    @autoreleasepool {
        const NSUInteger count = batch.size();
        // alloc/init rather than the +arrayWith… convenience constructors:
        // ARC owns these outright and releases them at scope exit without
        // involving the autorelease pool at all.
        NSMutableArray<NSData *> *packetsArray =
            [[NSMutableArray alloc] initWithCapacity:count];
        NSMutableArray<NSNumber *> *protocolsArray =
            [[NSMutableArray alloc] initWithCapacity:count];
        uint64_t batchBytes = 0;

        for (auto &pkt : batch) {
            const NSUInteger len = pkt.data.size();
            batchBytes += len;
            // Copy straight into the NSData. The previous heap OwnedBuffer +
            // dispatch_data_create + destructor block cost three extra
            // allocations per packet and, because dispatch_data_create with a
            // null queue submits its destructor to the default target queue,
            // deferred every free onto GCD — where it could lag arbitrarily
            // behind production under load. ARC frees this deterministically
            // when NE and this array both let go.
            [packetsArray addObject:[[NSData alloc] initWithBytes:pkt.data.data()
                                                           length:len]];
            [protocolsArray addObject:(pkt.ip_version == 6 ? _v6ProtocolNumber
                                                           : _v4ProtocolNumber)];
        }

        _totalWritePackets.fetch_add(count, std::memory_order_relaxed);
        _totalWriteBytes.fetch_add(batchBytes, std::memory_order_relaxed);
        if (![_packetFlow writePackets:packetsArray withProtocols:protocolsArray]) {
            _writeFailures.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

- (uint64_t)totalReadPackets { return _totalReadPackets.load(); }
- (uint64_t)totalReadBytes { return _totalReadBytes.load(); }
- (uint64_t)totalWritePackets { return _totalWritePackets.load(); }
- (uint64_t)totalWriteBytes { return _totalWriteBytes.load(); }
- (uint64_t)staleReadCallbacks { return _staleReadCallbacks.load(); }
- (uint64_t)writeFailures { return _writeFailures.load(); }

@end

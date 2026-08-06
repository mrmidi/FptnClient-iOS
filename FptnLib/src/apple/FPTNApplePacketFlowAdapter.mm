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
                std::vector<FPTNPacketDescriptor> descriptors(count);
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
                        .ipVersion = ipVer
                    };
                    batchBytes += data.length;
                }
                FPTNPacketInputResult result = [consumer consumePackets:descriptors.data() count:count];
                if (result == FPTNPacketInputResultAccepted) {
                    strongSelf->_totalReadPackets.fetch_add(count, std::memory_order_relaxed);
                    strongSelf->_totalReadBytes.fetch_add(batchBytes, std::memory_order_relaxed);
                }
            }
        }

        if (strongSelf->_running.load(std::memory_order_relaxed) &&
            strongSelf->_generation.load(std::memory_order_relaxed) == currentGen) {
            [strongSelf issueNextReadWithToken:token];
        }
    }];
}

- (void)sendEgressBatch:(fptn::tunnel::OwnedPacketBatch)batch {
    if (batch.empty()) {
        return;
    }
    NSUInteger count = batch.size();
    NSMutableArray<NSData *> *packetsArray = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *protocolsArray = [NSMutableArray arrayWithCapacity:count];
    uint64_t batchBytes = 0;

    for (auto &pkt : batch) {
        uint32_t len = static_cast<uint32_t>(pkt.data.size());
        batchBytes += len;
        auto *heapBuffer = new fptn::tunnel::OwnedBuffer(std::move(pkt.data));
        dispatch_data_t ddata = dispatch_data_create(heapBuffer->data(), len, NULL, ^{
            fptn_release_native_packet(heapBuffer);
        });
        NSData *nsData = (NSData *)ddata;
        [packetsArray addObject:nsData];
        [protocolsArray addObject:(pkt.ip_version == 6 ? _v6ProtocolNumber : _v4ProtocolNumber)];
    }

    _totalWritePackets.fetch_add(count, std::memory_order_relaxed);
    _totalWriteBytes.fetch_add(batchBytes, std::memory_order_relaxed);
    [_packetFlow writePackets:packetsArray withProtocols:protocolsArray];
}

- (uint64_t)totalReadPackets { return _totalReadPackets.load(); }
- (uint64_t)totalReadBytes { return _totalReadBytes.load(); }
- (uint64_t)totalWritePackets { return _totalWritePackets.load(); }
- (uint64_t)totalWriteBytes { return _totalWriteBytes.load(); }
- (uint64_t)staleReadCallbacks { return _staleReadCallbacks.load(); }

@end

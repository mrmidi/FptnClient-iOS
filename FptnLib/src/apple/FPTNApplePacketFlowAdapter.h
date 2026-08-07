/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include <cstdint>
#include <span>
#include <vector>

#ifndef FPTN_OWNED_PACKET_DEFINED
#define FPTN_OWNED_PACKET_DEFINED
namespace fptn::tunnel {
struct OwnedPacket {
    std::vector<std::uint8_t> data;
    std::uint8_t ip_version = 0;
};
using OwnedPacketBatch = std::vector<OwnedPacket>;
using OwnedPacketBatchView = std::span<const OwnedPacket>;
}
#endif
#endif

NS_ASSUME_NONNULL_BEGIN

/// Mirrors fptn::tunnel::PacketInputResult; the values must stay in the same
/// order because FPTNTunnelBridge casts between them.
typedef NS_ENUM(NSInteger, FPTNPacketInputResult) {
    FPTNPacketInputResultAccepted = 0,
    FPTNPacketInputResultQueueFull = 1,
    FPTNPacketInputResultTransportStopped = 2,
    FPTNPacketInputResultInvalidPacket = 3,
};

typedef struct {
    const uint8_t * _Nullable bytes;
    uint32_t length;
    uint8_t ipVersion;
    /// Retained backing object keeping `bytes` alive, released with
    /// fptn_release_ingress_packet(). The engine ingests asynchronously on its
    /// own runtime thread and may hold the bytes in a PBUF_REF well past the
    /// producing call, so a borrowed pointer alone is not enough. The consumer
    /// takes ownership on FPTNPacketInputResultAccepted and releases each
    /// owner exactly once; on any other result ownership stays with the
    /// producer.
    void * _Nullable owner;
} FPTNPacketDescriptor;

@protocol FPTNPacketBatchConsumer <NSObject>
- (FPTNPacketInputResult)consumePackets:(const FPTNPacketDescriptor * _Nonnull)packets count:(NSUInteger)count;
@end

@protocol FPTNPacketFlowIO <NSObject>
- (void)readPacketsWithCompletionHandler:(void (^ _Nonnull)(NSArray<NSData *> * _Nonnull packets, NSArray<NSNumber *> * _Nonnull protocols))completionHandler;
- (BOOL)writePackets:(NSArray<NSData *> * _Nonnull)packets withProtocols:(NSArray<NSNumber *> * _Nonnull)protocols;
@end

#ifdef __cplusplus
extern "C" {
#endif
void fptn_release_native_packet(void * _Nullable owner) noexcept;
/// Releases an FPTNPacketDescriptor.owner. Signature matches
/// fptn::tunnel::PacketLease::release so it can be installed directly.
void fptn_release_ingress_packet(void * _Nullable owner) noexcept;
#ifdef __cplusplus
}
#endif

@interface FPTNApplePacketFlowAdapter : NSObject

+ (BOOL)isFlowSupported;

- (instancetype)initWithPacketFlow:(id<FPTNPacketFlowIO>)packetFlow
                          consumer:(id<FPTNPacketBatchConsumer>)consumer;

- (void)start;
- (void)stop;

#ifdef __cplusplus
- (void)sendEgressBatch:(fptn::tunnel::OwnedPacketBatchView)batch;
#endif

@property (nonatomic, readonly) uint64_t totalReadPackets;
@property (nonatomic, readonly) uint64_t totalReadBytes;
@property (nonatomic, readonly) uint64_t totalWritePackets;
@property (nonatomic, readonly) uint64_t totalWriteBytes;
@property (nonatomic, readonly) uint64_t staleReadCallbacks;
/// Count of -writePackets:withProtocols: calls that returned NO. The result
/// was previously discarded, so write failures were invisible.
@property (nonatomic, readonly) uint64_t writeFailures;

@end

NS_ASSUME_NONNULL_END

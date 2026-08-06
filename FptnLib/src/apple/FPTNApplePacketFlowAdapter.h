/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include <cstdint>
#include <vector>

#ifndef FPTN_OWNED_PACKET_DEFINED
#define FPTN_OWNED_PACKET_DEFINED
namespace fptn::tunnel {
struct OwnedPacket {
    std::vector<std::uint8_t> data;
    std::uint8_t ip_version = 0;
};
using OwnedPacketBatch = std::vector<OwnedPacket>;
}
#endif
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FPTNPacketInputResult) {
    FPTNPacketInputResultAccepted = 0,
    FPTNPacketInputResultInvalidPacket = 1,
    FPTNPacketInputResultQueueFull = 2,
    FPTNPacketInputResultTransportStopped = 3,
};

typedef struct {
    const uint8_t * _Nullable bytes;
    uint32_t length;
    uint8_t ipVersion;
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
- (void)sendEgressBatch:(fptn::tunnel::OwnedPacketBatch)batch;
#endif

@property (nonatomic, readonly) uint64_t totalReadPackets;
@property (nonatomic, readonly) uint64_t totalReadBytes;
@property (nonatomic, readonly) uint64_t totalWritePackets;
@property (nonatomic, readonly) uint64_t totalWriteBytes;
@property (nonatomic, readonly) uint64_t staleReadCallbacks;

@end

NS_ASSUME_NONNULL_END

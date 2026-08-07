/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <Foundation/Foundation.h>
#import "FPTNApplePacketFlowAdapter.h"

NS_ASSUME_NONNULL_BEGIN

/// Snapshot of the flow data plane, mirroring fptn::tunnel::FlowCounters.
/// Kept as a plain C struct and copied field-by-field in the implementation so
/// no C++ type crosses into Swift and the two definitions can never drift into
/// an ODR conflict.
///
/// Reads as a funnel: whichever stage stops advancing is where packets die.
typedef struct {
    uint64_t inputPackets;
    uint64_t inputBytes;
    uint64_t ingressZeroCopyPackets;
    uint64_t ingressCopyPackets;
    uint64_t leasePoolExhaustions;
    uint64_t droppedPackets;

    uint64_t activeTcpFlows;
    uint64_t peakTcpFlows;
    uint64_t activeUdpFlows;
    uint64_t peakUdpFlows;
    uint64_t tcpBackpressureEvents;
    uint64_t tcpResets;
    uint64_t udpDrops;

    uint64_t tcpOutboundActive;
    uint64_t tcpOutboundOpenedTotal;
    uint64_t udpOutboundActive;

    uint64_t outputPackets;
    uint64_t outputBytes;
    /// Batches handed to the packet-flow adapter. outputPackets/egressBatches
    /// is the mean packets per -writePackets: call.
    uint64_t egressBatches;
} FPTNFlowCounters;

@interface FPTNTunnelBridge : NSObject <FPTNPacketBatchConsumer>

+ (BOOL)isFlowSupported;

- (instancetype)initWithTunIPv4:(NSString *)tunIPv4
                        tunIPv6:(nullable NSString *)tunIPv6
                            mtu:(uint16_t)mtu;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

- (void)setEgressAdapter:(nullable FPTNApplePacketFlowAdapter *)adapter;

/// Safe to call at any time, including after -stop: the engine retains its
/// final tallies so a post-mortem read reports the session rather than zeroes.
- (FPTNFlowCounters)flowCounters;

@property (nonatomic, readonly) BOOL isStarted;

@end

NS_ASSUME_NONNULL_END

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

/// Direct-only flow proxy. Development and profiling only: every flow leaves
/// via the device's own interface, so the user's real IP is exposed.
- (instancetype)initWithTunIPv4:(NSString *)tunIPv4
                        tunIPv6:(nullable NSString *)tunIPv6
                            mtu:(uint16_t)mtu;

/// Split routing: lwIP terminates the flows policy sends `direct` (and RSTs
/// those it rejects), while everything else is forwarded untouched to the
/// websocket transport `websocketBridge` already manages.
///
/// The transport is borrowed, not owned, so its reconnect and diagnostics keep
/// working and a reconnect leaves lwIP and its live flows alone. Supply it
/// with -setSplitTransport:.
///
/// Domains take the `domain:example.com` form or a bare domain, and match the
/// name plus any subdomain. Anything unmatched, or unattributable such as an
/// IP-literal connection, is tunnelled.
- (nullable instancetype)initSplitWithTunIPv4:(NSString *)tunIPv4
                                      tunIPv6:(nullable NSString *)tunIPv6
                                          mtu:(uint16_t)mtu
                                     serverIP:(NSString *)serverIP
                                   serverPort:(int)serverPort
                               directDomains:(NSArray<NSString *> *)directDomains
                               rejectDomains:(NSArray<NSString *> *)rejectDomains
                                 dropDomains:(NSArray<NSString *> *)dropDomains
                             tunnelResolvers:(NSArray<NSString *> *)tunnelResolvers;

/// Points the split plane at the websocket transport carrying `fptn`-verdict
/// packets. Pass a `WebsocketSwiftBridge *`.
///
/// The provider builds a **new** bridge per reconnect generation, so call this
/// on every (re)connect with the current one — and with NULL *before* dropping
/// the old bridge. The setter blocks until no ingress call is using the old
/// pointer, so honouring that order is what keeps it from dangling.
///
/// While NULL, `fptn`-verdict batches are refused instead of being queued into
/// a dead transport, and lwIP keeps running with its direct flows intact.
- (void)setSplitTransport:(nullable void *)websocketBridge;

/// Read-only tap for packets arriving from the transport, which is where DNS
/// answers appear and therefore where domain -> IP is learned. Call this from
/// the websocket inbound callback in split mode. No-op in flow-proxy mode.
- (void)observeInboundPacket:(const uint8_t *)bytes length:(size_t)length;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

- (void)setEgressAdapter:(nullable FPTNApplePacketFlowAdapter *)adapter;

/// Safe to call at any time, including after -stop: the engine retains its
/// final tallies so a post-mortem read reports the session rather than zeroes.
- (FPTNFlowCounters)flowCounters;

@property (nonatomic, readonly) BOOL isStarted;

@end

NS_ASSUME_NONNULL_END

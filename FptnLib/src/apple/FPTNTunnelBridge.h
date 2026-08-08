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

/// Split-routing view of the same session, mirroring SplitCounters,
/// ClassifierCounters and DnsObserverCounters. Zeroed in flow-proxy mode.
///
/// Reads as a funnel for the *routing* decision, the way FPTNFlowCounters does
/// for the packet path: if `dnsResponsesParsed` is zero the observer never saw
/// an answer, so every flow falls to the default verdict and nothing can ever
/// be routed direct.
typedef struct {
    uint64_t batches;
    uint64_t packetsToStack;
    uint64_t packetsToTransport;
    uint64_t packetsDropped;
    uint64_t rollbacks;

    uint64_t decisions;
    uint64_t tableHits;
    uint64_t unclassifiable;
    uint64_t activeFlows;

    uint64_t dnsResponsesParsed;
    uint64_t dnsMappingsRecorded;
    uint64_t dnsEntries;

    uint64_t routerUnknownFlows;
} FPTNSplitCounters;

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
/// `geoDatabaseDirectory` points at the shared app-group directory containing
/// the atomically-published `manifest.json` and `geo-routing.bin` artifact.
/// The app compiles the raw `geoip.dat`/`geosite.dat` pair before publishing
/// that artifact. The tunnel only maps the artifact; it never compiles or
/// parses the source lists on its packet-routing path. The domain arrays remain
/// a compatibility fallback for native callers; production passes them empty.
- (nullable instancetype)initSplitWithTunIPv4:(NSString *)tunIPv4
                                      tunIPv6:(nullable NSString *)tunIPv6
                                          mtu:(uint16_t)mtu
                                   serverIP:(NSString *)serverIP
                                 serverPort:(int)serverPort
                             directDomains:(NSArray<NSString *> *)directDomains
                               rejectDomains:(NSArray<NSString *> *)rejectDomains
                                 dropDomains:(NSArray<NSString *> *)dropDomains
                             tunnelResolvers:(NSArray<NSString *> *)tunnelResolvers
                         geoDatabaseDirectory:(nullable NSString *)geoDatabaseDirectory;

/// Compiles the raw `geoip.dat`/`geosite.dat` pair in the shared app-group
/// directory and atomically publishes `geo-routing.bin` there. The existing
/// published artifact is never modified in place. This is intended for the
/// app process, immediately after it has downloaded and atomically written the
/// two source files, before it writes `manifest.json` as the commit marker.
+ (BOOL)compileGeoRoutingPolicyAtPath:(NSString *)directoryPath
                                error:(NSError * _Nullable * _Nullable)error;

/// Whether the compiled geo policy is actually driving this tunnel, and if not,
/// why. Reads `active (…)` with the rule counts, or `inactive (…)` naming the
/// reason — no published manifest, no artifact, a rejected artifact.
///
/// Deliberately a value the platform layer can log through its own logger:
/// whether geo routing is live is the one thing that must be answerable from an
/// ordinary log capture, without attaching a stream to the native output.
@property (nonatomic, readonly, copy) NSString *geoRoutingStatus;

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

/// Split-routing counters. All zero outside split mode.
- (FPTNSplitCounters)splitCounters;

@property (nonatomic, readonly) BOOL isStarted;

@end

NS_ASSUME_NONNULL_END

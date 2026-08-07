/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <XCTest/XCTest.h>
#include <arpa/inet.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <atomic>
#include <thread>
#include <vector>
#include <sys/resource.h>
#include <sys/socket.h>
#include <netinet/in.h>
#import <fptn_native_lib/src/apple/FPTNApplePacketFlowAdapter.h>
#import <fptn_native_lib/src/apple/FPTNTunnelBridge.h>

#pragma mark - IPv4/TCP test packet helpers

/// Folded one's-complement sum over big-endian 16-bit words. The seed lets the
/// TCP pseudo-header be chained into the header sum.
static uint16_t FPTNOnesComplementSum(const uint8_t *data, size_t length, uint32_t seed) {
    uint32_t sum = seed;
    size_t i = 0;
    for (; i + 1 < length; i += 2) {
        sum += (uint32_t)((data[i] << 8) | data[i + 1]);
    }
    if (i < length) {
        sum += (uint32_t)(data[i] << 8);
    }
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFFU) + (sum >> 16);
    }
    return (uint16_t)sum;
}

/// A 40-byte IPv4 TCP SYN with valid IP and TCP checksums. lwipopts.h overrides
/// no CHECKSUM_CHECK_* option, so lwIP validates both and would silently drop a
/// lazily built packet — the test would then fail for the wrong reason. DF is
/// set with a zero fragment offset so RequiresWritableIngress() returns false
/// and ingress takes the zero-copy PBUF_REF path rather than the memcpy
/// fallback, which is the path that actually ships.
static NSData *FPTNMakeTcpSyn(const char *sourceIP,
                              uint16_t sourcePort,
                              const char *destinationIP,
                              uint16_t destinationPort) {
    uint8_t packet[40] = {0};

    struct in_addr source = {0};
    struct in_addr destination = {0};
    inet_pton(AF_INET, sourceIP, &source);
    inet_pton(AF_INET, destinationIP, &destination);

    packet[0] = 0x45;                    // IPv4, IHL 5
    packet[2] = 0x00; packet[3] = 0x28;  // total length 40
    packet[4] = 0x00; packet[5] = 0x01;  // identification
    packet[6] = 0x40;                    // DF, fragment offset 0
    packet[8] = 0x40;                    // TTL 64
    packet[9] = 0x06;                    // protocol TCP
    memcpy(&packet[12], &source.s_addr, 4);
    memcpy(&packet[16], &destination.s_addr, 4);

    const uint16_t ipChecksum = (uint16_t)~FPTNOnesComplementSum(packet, 20, 0);
    packet[10] = (uint8_t)(ipChecksum >> 8);
    packet[11] = (uint8_t)(ipChecksum & 0xFFU);

    uint8_t *tcp = packet + 20;
    tcp[0] = (uint8_t)(sourcePort >> 8);
    tcp[1] = (uint8_t)(sourcePort & 0xFFU);
    tcp[2] = (uint8_t)(destinationPort >> 8);
    tcp[3] = (uint8_t)(destinationPort & 0xFFU);
    tcp[7] = 0x01;                       // sequence number 1
    tcp[12] = 0x50;                      // data offset 5, no options
    tcp[13] = 0x02;                      // SYN
    tcp[14] = 0xFF; tcp[15] = 0xFF;      // window

    uint8_t pseudoHeader[12] = {0};
    memcpy(&pseudoHeader[0], &source.s_addr, 4);
    memcpy(&pseudoHeader[4], &destination.s_addr, 4);
    pseudoHeader[9] = 0x06;              // protocol
    pseudoHeader[11] = 0x14;             // TCP length 20

    const uint32_t seed = FPTNOnesComplementSum(pseudoHeader, sizeof(pseudoHeader), 0);
    const uint16_t tcpChecksum = (uint16_t)~FPTNOnesComplementSum(tcp, 20, seed);
    tcp[16] = (uint8_t)(tcpChecksum >> 8);
    tcp[17] = (uint8_t)(tcpChecksum & 0xFFU);

    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

/// Live bytes in the default malloc zone. Coarse, but a leak of thousands of
/// ~1.4 KB packet buffers dwarfs the noise floor by orders of magnitude.
static size_t FPTNLiveHeapBytes(void) {
    malloc_statistics_t stats = {};
    malloc_zone_statistics(malloc_default_zone(), &stats);
    return stats.size_in_use;
}

/// Resident cost as the OS accounts it. This — not the malloc zone total — is
/// what jetsam measures against the network extension's ~50 MB budget: it
/// counts dirty pages malloc has freed but not returned, and everything
/// allocated outside the default zone, both of which `size_in_use` misses.
static size_t FPTNPhysFootprintBytes(void) {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t kr =
        task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS || count < TASK_VM_INFO_REV1_COUNT) {
        return 0;   // phys_footprint unavailable on this revision
    }
    return (size_t)info.phys_footprint;
}

/// User + system CPU across every thread in the process, so work done on the
/// lwIP runtime and GCD queues is counted, not just the test thread.
static double FPTNProcessCpuSeconds(void) {
    struct rusage usage = {};
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return 0.0;
    }
    const auto seconds = [](struct timeval tv) {
        return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
    };
    return seconds(usage.ru_utime) + seconds(usage.ru_stime);
}

/// One reading of everything that constrains the data plane on device.
struct FPTNResourceSample {
    size_t footprintBytes = 0;   ///< phys_footprint: the jetsam metric
    size_t heapBytes = 0;        ///< default malloc zone, live
    unsigned heapBlocks = 0;     ///< live block count ~ Instruments "persistent"
    double cpuSeconds = 0.0;
};

static FPTNResourceSample FPTNSampleResources(void) {
    malloc_statistics_t stats = {};
    malloc_zone_statistics(malloc_default_zone(), &stats);
    FPTNResourceSample sample;
    sample.footprintBytes = FPTNPhysFootprintBytes();
    sample.heapBytes = stats.size_in_use;
    sample.heapBlocks = stats.blocks_in_use;
    sample.cpuSeconds = FPTNProcessCpuSeconds();
    return sample;
}

/// sendEgressBatch hands each buffer to dispatch_data_create with a NULL
/// queue, so the destructor block — and therefore the delete — is submitted
/// asynchronously to the default target queue. Measuring immediately would
/// race the frees, so settle first: sample until the live-byte count stops
/// shrinking, or give up after `limit`.
///
/// Frees arrive in bursts (GCD destructor blocks, lwIP timers, flow expiry),
/// so a single non-improving sample means nothing — stopping on the first one
/// reports a plateau mid-drain as the settled value. Require a run of
/// consecutive quiet samples instead.
static size_t FPTNSettledHeapBytes(NSTimeInterval limit) {
    static const int kQuietSamplesRequired = 8;   // 8 x 50 ms = 400 ms quiet
    size_t best = FPTNLiveHeapBytes();
    int quiet = 0;
    const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + limit;
    while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        const size_t now = FPTNLiveHeapBytes();
        if (now < best) {
            best = now;
            quiet = 0;
            continue;
        }
        if (++quiet >= kQuietSamplesRequired) {
            break;
        }
    }
    return best;
}

/// IPv4/UDP datagram with a valid IP checksum. The UDP checksum is left at 0,
/// which IPv4 defines as "not computed" and lwIP therefore skips verifying —
/// so a load generator does not pay for a checksum per packet.
///
/// UDP rather than TCP on purpose: no handshake and no sequence bookkeeping,
/// so the generator stays small while still driving the allocation paths under
/// investigation (one retained NSData per ingress packet, one OwnedBuffer per
/// egress packet), which are per-packet and indifferent to transport.
static NSData *FPTNMakeUdpDatagram(const char *sourceIP,
                                   uint16_t sourcePort,
                                   const char *destinationIP,
                                   uint16_t destinationPort,
                                   size_t payloadBytes) {
    const size_t total = 20 + 8 + payloadBytes;
    NSMutableData *buffer = [NSMutableData dataWithLength:total];
    uint8_t *packet = (uint8_t *)buffer.mutableBytes;

    struct in_addr source = {0};
    struct in_addr destination = {0};
    inet_pton(AF_INET, sourceIP, &source);
    inet_pton(AF_INET, destinationIP, &destination);

    packet[0] = 0x45;
    packet[2] = (uint8_t)(total >> 8);
    packet[3] = (uint8_t)(total & 0xFFU);
    packet[4] = 0x00; packet[5] = 0x01;
    packet[6] = 0x40;                     // DF, offset 0 → zero-copy ingress
    packet[8] = 0x40;                     // TTL
    packet[9] = 0x11;                     // UDP
    memcpy(&packet[12], &source.s_addr, 4);
    memcpy(&packet[16], &destination.s_addr, 4);
    const uint16_t ipChecksum = (uint16_t)~FPTNOnesComplementSum(packet, 20, 0);
    packet[10] = (uint8_t)(ipChecksum >> 8);
    packet[11] = (uint8_t)(ipChecksum & 0xFFU);

    uint8_t *udp = packet + 20;
    udp[0] = (uint8_t)(sourcePort >> 8);
    udp[1] = (uint8_t)(sourcePort & 0xFFU);
    udp[2] = (uint8_t)(destinationPort >> 8);
    udp[3] = (uint8_t)(destinationPort & 0xFFU);
    const uint16_t udpLength = (uint16_t)(8 + payloadBytes);
    udp[4] = (uint8_t)(udpLength >> 8);
    udp[5] = (uint8_t)(udpLength & 0xFFU);
    // udp[6..7] checksum stays 0.
    memset(udp + 8, 0x5A, payloadBytes);
    return buffer;
}

static BOOL FPTNIsTcpSynAck(NSData *packet) {
    if (packet.length < 40) {
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)packet.bytes;
    if ((bytes[0] >> 4) != 4 || bytes[9] != 0x06) {
        return NO;
    }
    const size_t headerLength = (size_t)(bytes[0] & 0x0FU) * 4;
    if (packet.length < headerLength + 20) {
        return NO;
    }
    const uint8_t flags = bytes[headerLength + 13];
    return (flags & 0x12U) == 0x12U;  // SYN | ACK
}

@interface MockPacketFlow : NSObject <FPTNPacketFlowIO>
@property (nonatomic, copy) void (^readBlock)(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *));
@property (nonatomic, copy, nullable) void (^onWrite)(NSArray<NSData *> *packets);
@property (nonatomic, readonly) NSMutableArray<NSArray<NSData *> *> *writtenBatches;
@property (nonatomic, readonly) NSMutableArray<NSArray<NSNumber *> *> *writtenProtocols;
@end

@implementation MockPacketFlow
- (instancetype)init {
    self = [super init];
    if (self) {
        _writtenBatches = [NSMutableArray array];
        _writtenProtocols = [NSMutableArray array];
    }
    return self;
}

- (void)readPacketsWithCompletionHandler:(void (^)(NSArray<NSData *> * _Nonnull, NSArray<NSNumber *> * _Nonnull))completionHandler {
    if (self.readBlock) {
        self.readBlock(completionHandler);
    }
}

- (BOOL)writePackets:(NSArray<NSData *> *)packets withProtocols:(NSArray<NSNumber *> *)protocols {
    // Egress arrives on the lwIP runtime thread while tests observe from the
    // test thread.
    @synchronized (self) {
        [self.writtenBatches addObject:packets];
        [self.writtenProtocols addObject:protocols];
    }
    void (^notify)(NSArray<NSData *> *) = self.onWrite;
    if (notify) {
        notify(packets);
    }
    return YES;
}
@end

@interface MockConsumer : NSObject <FPTNPacketBatchConsumer>
@property (nonatomic, assign) FPTNPacketInputResult resultToReturn;
@property (nonatomic, readonly) NSUInteger consumedBatchCount;
@property (nonatomic, readonly) NSUInteger consumedPacketCount;
@end

@implementation MockConsumer
- (instancetype)init {
    self = [super init];
    if (self) {
        _resultToReturn = FPTNPacketInputResultAccepted;
    }
    return self;
}

- (FPTNPacketInputResult)consumePackets:(const FPTNPacketDescriptor *)packets count:(NSUInteger)count {
    _consumedBatchCount += 1;
    _consumedPacketCount += count;
    return self.resultToReturn;
}
@end

@interface FptnAppleBridgeTests : XCTestCase
@end

@implementation FptnAppleBridgeTests

- (void)testAdapterPumpAcceptsAndDiscardsStale {
    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    MockConsumer *consumer = [[MockConsumer alloc] init];
    FPTNApplePacketFlowAdapter *adapter = [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:consumer];

    __block void (^pendingCompletion)(NSArray<NSData *> *, NSArray<NSNumber *> *) = nil;
    flow.readBlock = ^(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *)) {
        pendingCompletion = completion;
    };

    [adapter start];
    XCTAssertNotNil(pendingCompletion);

    uint8_t pktData[] = {0x45, 0x00, 0x00, 0x14};
    NSData *packet = [NSData dataWithBytes:pktData length:sizeof(pktData)];
    pendingCompletion(@[packet], @[@(AF_INET)]);

    XCTAssertEqual(consumer.consumedBatchCount, 1UL);
    XCTAssertEqual(consumer.consumedPacketCount, 1UL);
    XCTAssertEqual(adapter.totalReadPackets, 1ULL);
    XCTAssertEqual(adapter.totalReadBytes, 4ULL);

    void (^staleCompletion)(NSArray<NSData *> *, NSArray<NSNumber *> *) = pendingCompletion;
    [adapter stop];

    staleCompletion(@[packet], @[@(AF_INET)]);
    XCTAssertEqual(consumer.consumedBatchCount, 1UL);
    XCTAssertEqual(adapter.staleReadCallbacks, 1ULL);
}

- (void)testAdapterEgressWritesData {
    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    MockConsumer *consumer = [[MockConsumer alloc] init];
    FPTNApplePacketFlowAdapter *adapter = [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:consumer];

    fptn::tunnel::OwnedPacketBatch batch;
    fptn::tunnel::OwnedPacket pkt;
    pkt.data = {0x45, 0x00, 0x00, 0x14};
    pkt.ip_version = 4;
    batch.push_back(std::move(pkt));

    [adapter sendEgressBatch:fptn::tunnel::OwnedPacketBatchView(batch)];

    XCTAssertEqual(flow.writtenBatches.count, 1UL);
    XCTAssertEqual(flow.writtenBatches[0].count, 1UL);
    XCTAssertEqual(adapter.totalWritePackets, 1ULL);
    XCTAssertEqual(adapter.totalWriteBytes, 4ULL);
}

- (void)testTunnelBridgeSmokeStartStop {
    FPTNTunnelBridge *bridge = [[FPTNTunnelBridge alloc] initWithTunIPv4:@"10.8.0.2" tunIPv6:@"fd00::1" mtu:1400];
    XCTAssertNotNil(bridge);

    if ([FPTNTunnelBridge isFlowSupported]) {
        NSError *error = nil;
        BOOL ok = [bridge startWithError:&error];
        XCTAssertTrue(ok);
        XCTAssertNil(error);
        XCTAssertTrue(bridge.isStarted);

        [bridge stop];
        XCTAssertFalse(bridge.isStarted);
    }
}

/// End-to-end ingress test across the real adapter, bridge and lwIP stack.
///
/// The ownership contract in packet_types.h requires a PacketLease's bytes to
/// stay valid until its release hook runs. LwipStack::InputPackets validates
/// the batch synchronously but posts it to the TunnelRuntime thread and ingests
/// it there, so the NSData behind the descriptors must outlive the read
/// callback — exactly what NEPacketTunnelFlow does not guarantee.
///
/// lwIP completes the handshake on the listening pcb itself, so a lone SYN
/// yields a SYN-ACK without any outbound connection: no network is touched, and
/// the assertion isolates the ingress path from routing and outbound entirely.
- (void)testIngressLeaseOutlivesReadCallbackAndProducesSynAck {
    if (![FPTNTunnelBridge isFlowSupported]) {
        XCTSkip(@"framework built without lwIP (FPTN_WITH_LWIP=0)");
    }

    FPTNTunnelBridge *bridge = [[FPTNTunnelBridge alloc] initWithTunIPv4:@"10.8.0.2" tunIPv6:nil mtu:1400];
    NSError *startError = nil;
    XCTAssertTrue([bridge startWithError:&startError], @"bridge failed to start: %@", startError);

    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    __block void (^pendingCompletion)(NSArray<NSData *> *, NSArray<NSNumber *> *) = nil;
    flow.readBlock = ^(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *)) {
        pendingCompletion = completion;
    };

    XCTestExpectation *sawSynAck =
        [self expectationWithDescription:@"lwIP writes a SYN-ACK back to the packet flow"];
    sawSynAck.assertForOverFulfill = NO;
    flow.onWrite = ^(NSArray<NSData *> *packets) {
        for (NSData *packet in packets) {
            if (FPTNIsTcpSynAck(packet)) {
                [sawSynAck fulfill];
            }
        }
    };

    FPTNApplePacketFlowAdapter *adapter =
        [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:bridge];
    [bridge setEgressAdapter:adapter];
    [self addTeardownBlock:^{
        [adapter stop];
        [bridge stop];
    }];

    [adapter start];
    XCTAssertNotNil(pendingCompletion, @"adapter did not issue a read");

    // Hold the block alive across the call: the adapter re-issues its read from
    // inside this invocation, which reassigns pendingCompletion.
    void (^deliver)(NSArray<NSData *> *, NSArray<NSNumber *> *) = pendingCompletion;

    // Deliver exactly as NEPacketTunnelFlow does — the NSData belongs to the
    // callback and dies the moment it returns.
    @autoreleasepool {
        deliver(@[FPTNMakeTcpSyn("10.8.0.2", 40001, "192.0.2.1", 80)], @[@(AF_INET)]);
    }

    // Reuse the freed allocation so a dangling PBUF_REF reads poison rather
    // than stale-but-intact bytes; without this the failure is a race.
    NSMutableArray<NSMutableData *> *churn = [NSMutableArray arrayWithCapacity:512];
    for (int i = 0; i < 512; ++i) {
        NSMutableData *block = [NSMutableData dataWithLength:40];
        memset(block.mutableBytes, 0x55, block.length);
        [churn addObject:block];
    }

    [self waitForExpectations:@[sawSynAck] timeout:2.0];
}

/// Control for the test above. Byte-for-byte the same packet through the same
/// path; the single variable is that the NSData is kept alive for the whole
/// test instead of dying with the read callback.
///
///   this passes, the other fails  -> lease lifetime is the cause
///   both fail                     -> the packet or the lwIP netif/bind is at
///                                    fault and the lifetime bug is a second,
///                                    independent defect
- (void)testIngressProducesSynAckWhenPacketIsKeptAlive {
    if (![FPTNTunnelBridge isFlowSupported]) {
        XCTSkip(@"framework built without lwIP (FPTN_WITH_LWIP=0)");
    }

    FPTNTunnelBridge *bridge = [[FPTNTunnelBridge alloc] initWithTunIPv4:@"10.8.0.2" tunIPv6:nil mtu:1400];
    NSError *startError = nil;
    XCTAssertTrue([bridge startWithError:&startError], @"bridge failed to start: %@", startError);

    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    __block void (^pendingCompletion)(NSArray<NSData *> *, NSArray<NSNumber *> *) = nil;
    flow.readBlock = ^(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *)) {
        pendingCompletion = completion;
    };

    XCTestExpectation *sawSynAck =
        [self expectationWithDescription:@"lwIP writes a SYN-ACK back to the packet flow"];
    sawSynAck.assertForOverFulfill = NO;
    flow.onWrite = ^(NSArray<NSData *> *packets) {
        for (NSData *packet in packets) {
            if (FPTNIsTcpSynAck(packet)) {
                [sawSynAck fulfill];
            }
        }
    };

    FPTNApplePacketFlowAdapter *adapter =
        [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:bridge];
    [bridge setEgressAdapter:adapter];
    [self addTeardownBlock:^{
        [adapter stop];
        [bridge stop];
    }];

    [adapter start];
    XCTAssertNotNil(pendingCompletion, @"adapter did not issue a read");

    void (^deliver)(NSArray<NSData *> *, NSArray<NSNumber *> *) = pendingCompletion;

    // The only difference from the failing test: this strong reference keeps
    // the backing buffer valid well past the read callback.
    NSData *syn = FPTNMakeTcpSyn("10.8.0.2", 40001, "192.0.2.1", 80);
    deliver(@[syn], @[@(AF_INET)]);

    [self waitForExpectations:@[sawSynAck] timeout:2.0];

    // Real use after the wait so ARC cannot release `syn` early.
    XCTAssertEqual(syn.length, 40UL);
}

/// Sustained-egress leak check, targeting the allocation profile seen on
/// device: ~8,000 persistent `Malloc 1.50 KiB` blocks alongside a near-equal
/// count of persistent `__NSArrayM`, growing until jetsam.
///
/// sendEgressBatch allocates one heap OwnedBuffer per packet plus two
/// NSMutableArrays per batch, and each buffer is freed only by the
/// dispatch_data destructor block. This drives that path hard, drops the
/// consumer's references the way NEPacketTunnelFlow eventually does, and
/// asserts the heap comes back down. Needs no lwIP and no NetworkExtension,
/// so it runs anywhere the framework builds.
- (void)testSustainedEgressDoesNotAccumulateBuffers {
    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    MockConsumer *consumer = [[MockConsumer alloc] init];
    FPTNApplePacketFlowAdapter *adapter =
        [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:consumer];

    static const NSUInteger kPacketsPerBatch = 32;
    static const NSUInteger kBatches = 200;
    static const size_t kPacketBytes = 1400;
    const size_t totalBytes = kBatches * kPacketsPerBatch * kPacketBytes;

    const auto pump = ^(NSUInteger batches) {
        for (NSUInteger b = 0; b < batches; ++b) {
            @autoreleasepool {
                fptn::tunnel::OwnedPacketBatch batch;
                batch.reserve(kPacketsPerBatch);
                for (NSUInteger i = 0; i < kPacketsPerBatch; ++i) {
                    fptn::tunnel::OwnedPacket pkt;
                    pkt.data.assign(kPacketBytes, 0x41);
                    pkt.ip_version = 4;
                    batch.push_back(std::move(pkt));
                }
                [adapter sendEgressBatch:fptn::tunnel::OwnedPacketBatchView(batch)];
                // Stand in for NE draining its queue: release what the flow
                // captured, leaving the dispatch_data destructors as the only
                // thing keeping the buffers alive.
                @synchronized (flow) {
                    [flow.writtenBatches removeAllObjects];
                    [flow.writtenProtocols removeAllObjects];
                }
            }
        }
    };

    // Warm up so first-touch allocations are not counted as growth.
    pump(10);
    const size_t before = FPTNSettledHeapBytes(2.0);

    pump(kBatches);
    const size_t after = FPTNSettledHeapBytes(5.0);

    const size_t retained = after > before ? after - before : 0;
    XCTAssertLessThan(retained, totalBytes / 10,
        @"egress retained %zu bytes of %zu pushed — buffers are not being freed",
        retained, totalBytes);
}

/// Sustained end-to-end load through the real stack: synthetic ingress →
/// adapter (one retained NSData per packet) → lwIP → DirectUdpOutbound → a
/// loopback echo server → back through lwIP → egress. This is the macOS
/// reproduction of the device profile that showed ~8,000 persistent
/// `Malloc 1.50 KiB` blocks growing until jetsam.
///
/// Self-diagnosing: it asserts on flowCounters first, so a failure tells you
/// whether packets actually reached lwIP rather than just that memory grew.
/// Profile it with Instruments (Allocations + Record reference counts) to get
/// the retain history behind any growth this reports.
- (void)testSustainedFlowLoadDoesNotGrowHeap {
    if (![FPTNTunnelBridge isFlowSupported]) {
        XCTSkip(@"framework built without lwIP (FPTN_WITH_LWIP=0)");
    }

    // Loopback echo server, so egress is exercised too.
    const int server = socket(AF_INET, SOCK_DGRAM, 0);
    XCTAssertGreaterThanOrEqual(server, 0, @"socket() failed");
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    XCTAssertEqual(bind(server, (struct sockaddr *)&addr, sizeof(addr)), 0, @"bind() failed");
    socklen_t addrLen = sizeof(addr);
    XCTAssertEqual(getsockname(server, (struct sockaddr *)&addr, &addrLen), 0);
    const uint16_t serverPort = ntohs(addr.sin_port);

    std::atomic<bool> echoRunning{true};
    std::thread echo([server, &echoRunning] {
        std::vector<std::uint8_t> buf(2048);
        while (echoRunning.load(std::memory_order_relaxed)) {
            struct sockaddr_in from = {};
            socklen_t fromLen = sizeof(from);
            const ssize_t n = recvfrom(server, buf.data(), buf.size(), 0,
                                       (struct sockaddr *)&from, &fromLen);
            if (n <= 0) {
                break;
            }
            (void)sendto(server, buf.data(), (size_t)n, 0,
                         (struct sockaddr *)&from, fromLen);
        }
    });

    FPTNTunnelBridge *bridge = [[FPTNTunnelBridge alloc] initWithTunIPv4:@"10.8.0.2" tunIPv6:nil mtu:1400];
    NSError *startError = nil;
    XCTAssertTrue([bridge startWithError:&startError], @"bridge failed to start: %@", startError);

    MockPacketFlow *flow = [[MockPacketFlow alloc] init];
    __block void (^pendingCompletion)(NSArray<NSData *> *, NSArray<NSNumber *> *) = nil;
    flow.readBlock = ^(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *)) {
        pendingCompletion = completion;
    };
    // Stand in for NE consuming what it is handed. The mock otherwise retains
    // every batch forever, and egress keeps arriving all through the settle
    // window after the drive loop stops — which shows up as ~1 KB retained per
    // egress packet and looks exactly like a data-plane leak. Drain here, at
    // the point of write, so nothing depends on the driver's timing.
    __weak MockPacketFlow *weakFlow = flow;
    flow.onWrite = ^(NSArray<NSData *> *packets) {
        (void)packets;
        MockPacketFlow *strongFlow = weakFlow;
        if (strongFlow == nil) {
            return;
        }
        @synchronized (strongFlow) {
            [strongFlow.writtenBatches removeAllObjects];
            [strongFlow.writtenProtocols removeAllObjects];
        }
    };

    FPTNApplePacketFlowAdapter *adapter =
        [[FPTNApplePacketFlowAdapter alloc] initWithPacketFlow:flow consumer:bridge];
    [bridge setEgressAdapter:adapter];
    [self addTeardownBlock:^{
        [adapter stop];
        [bridge stop];
    }];
    [adapter start];
    XCTAssertNotNil(pendingCompletion);

    static const NSUInteger kBatches = 400;
    static const NSUInteger kPacketsPerBatch = 16;
    static const size_t kPayloadBytes = 1200;
    const size_t pushedBytes = kBatches * kPacketsPerBatch * (kPayloadBytes + 28);

    // Number of distinct source ports, and therefore of concurrent UDP flows.
    // Overridable so the same binary can be run at two flow counts to separate
    // per-flow cost from the fixed baseline: retained(N) - retained(M) over
    // N - M is the per-flow term, which is what has to stay flat.
    NSUInteger distinctFlows = 64;
    if (const char *env = getenv("FPTN_LOAD_FLOWS")) {
        const long parsed = strtol(env, NULL, 10);
        if (parsed > 0) {
            distinctFlows = (NSUInteger)parsed;
        }
    }

    const auto drive = ^(NSUInteger batches) {
        for (NSUInteger b = 0; b < batches; ++b) {
            void (^deliver)(NSArray<NSData *> *, NSArray<NSNumber *> *) = pendingCompletion;
            if (deliver == nil) {
                break;
            }
            @autoreleasepool {
                NSMutableArray<NSData *> *packets = [NSMutableArray arrayWithCapacity:kPacketsPerBatch];
                NSMutableArray<NSNumber *> *protocols = [NSMutableArray arrayWithCapacity:kPacketsPerBatch];
                for (NSUInteger i = 0; i < kPacketsPerBatch; ++i) {
                    // Vary the source port so the stack builds many UDP flows,
                    // as a real device would.
                    const uint16_t sport =
                        (uint16_t)(20000 + ((b * kPacketsPerBatch + i) % distinctFlows));
                    [packets addObject:FPTNMakeUdpDatagram("10.8.0.2", sport, "127.0.0.1", serverPort, kPayloadBytes)];
                    [protocols addObject:@(AF_INET)];
                }
                deliver(packets, protocols);
            }
            if ((b % 32) == 0) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            }
        }
    };

    drive(32);
    const size_t before = FPTNSettledHeapBytes(2.0);
    const FPTNResourceSample baseline = FPTNSampleResources();
    drive(kBatches);
    const size_t after = FPTNSettledHeapBytes(8.0);
    const FPTNResourceSample loaded = FPTNSampleResources();

    const FPTNFlowCounters c = [bridge flowCounters];
    const ssize_t heapDelta = (ssize_t)after - (ssize_t)before;
    const ssize_t footprintDelta =
        (ssize_t)loaded.footprintBytes - (ssize_t)baseline.footprintBytes;
    const ssize_t blockDelta =
        (ssize_t)loaded.heapBlocks - (ssize_t)baseline.heapBlocks;
    const double cpuDelta = loaded.cpuSeconds - baseline.cpuSeconds;
    const uint64_t handled = c.inputPackets + c.outputPackets;

    NSLog(@"flow load: lwip_in=%llu dropped=%llu zerocopy=%llu copy=%llu "
           "udp_flows=%llu/%llu outbound_udp=%llu out=%llu "
           "batches=%llu avg_batch=%.1f write_fail=%llu",
          c.inputPackets, c.droppedPackets, c.ingressZeroCopyPackets,
          c.ingressCopyPackets, c.activeUdpFlows, c.peakUdpFlows,
          c.udpOutboundActive, c.outputPackets, c.egressBatches,
          c.egressBatches > 0
              ? (double)c.outputPackets / (double)c.egressBatches
              : 0.0,
          adapter.writeFailures);
    NSLog(@"flow cost: footprint=%.2f MiB (%+.2f MiB) heap=%+zd B blocks=%+zd "
           "cpu=%.3f s (%.1f us/pkt) per_flow=%zd B",
          (double)loaded.footprintBytes / (1024.0 * 1024.0),
          (double)footprintDelta / (1024.0 * 1024.0),
          heapDelta, blockDelta, cpuDelta,
          handled > 0 ? (cpuDelta * 1e6) / (double)handled : 0.0,
          c.peakUdpFlows > 0 ? heapDelta / (ssize_t)c.peakUdpFlows : 0);

    echoRunning.store(false, std::memory_order_relaxed);
    shutdown(server, SHUT_RDWR);
    close(server);
    echo.join();

    // Diagnose before asserting on memory: growth means nothing if the packets
    // never reached the stack in the first place.
    XCTAssertGreaterThan(c.inputPackets, 0ULL, @"no packets reached lwIP");
    XCTAssertGreaterThan(c.peakUdpFlows, 0ULL, @"lwIP created no UDP flows — destination rejected?");

    const size_t retained = after > before ? after - before : 0;
    XCTAssertLessThan(retained, pushedBytes / 10,
        @"stack retained %zu bytes after pushing %zu — matches the device growth profile",
        retained, pushedBytes);
}

@end

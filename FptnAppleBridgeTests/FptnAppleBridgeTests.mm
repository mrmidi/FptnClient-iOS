/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <XCTest/XCTest.h>
#include <sys/socket.h>
#include <netinet/in.h>
#import <fptn_native_lib/src/apple/FPTNApplePacketFlowAdapter.h>
#import <fptn_native_lib/src/apple/FPTNTunnelBridge.h>

@interface MockPacketFlow : NSObject <FPTNPacketFlowIO>
@property (nonatomic, copy) void (^readBlock)(void (^completion)(NSArray<NSData *> *, NSArray<NSNumber *> *));
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
    [self.writtenBatches addObject:packets];
    [self.writtenProtocols addObject:protocols];
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

    [adapter sendEgressBatch:std::move(batch)];

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

@end

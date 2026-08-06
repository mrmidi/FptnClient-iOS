/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import <Foundation/Foundation.h>
#import "FPTNApplePacketFlowAdapter.h"

NS_ASSUME_NONNULL_BEGIN

@interface FPTNTunnelBridge : NSObject <FPTNPacketBatchConsumer>

+ (BOOL)isFlowSupported;

- (instancetype)initWithTunIPv4:(NSString *)tunIPv4
                        tunIPv6:(nullable NSString *)tunIPv6
                            mtu:(uint16_t)mtu;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

- (void)setEgressAdapter:(nullable FPTNApplePacketFlowAdapter *)adapter;

@property (nonatomic, readonly) BOOL isStarted;

@end

NS_ASSUME_NONNULL_END

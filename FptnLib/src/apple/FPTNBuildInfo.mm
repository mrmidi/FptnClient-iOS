/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import "FPTNBuildInfo.h"

#include <TargetConditionals.h>

// Injected by FptnLib/CMakeLists.txt. The fallbacks keep the framework
// buildable outside build_fptn_lib.sh; "unknown" reading back is itself the
// signal that the build did not come through the supported path.
#ifndef FPTN_BUILD_CONFIGURATION
#define FPTN_BUILD_CONFIGURATION "unknown"
#endif
#ifndef FPTN_BUILD_COMMIT
#define FPTN_BUILD_COMMIT "unknown"
#endif
#ifndef FPTN_BUILD_TARGET
#define FPTN_BUILD_TARGET "unknown"
#endif

@implementation FPTNBuildInfo

+ (NSString *)configuration {
    return @FPTN_BUILD_CONFIGURATION;
}

+ (NSString *)target {
    return @FPTN_BUILD_TARGET;
}

+ (NSString *)platform {
#if TARGET_OS_SIMULATOR
#if TARGET_OS_TV
    return @"tvos-simulator";
#else
    return @"ios-simulator";
#endif
#elif TARGET_OS_TV
    return @"tvos-device";
#elif TARGET_OS_IOS
    return @"ios-device";
#elif TARGET_OS_OSX
    return @"macos";
#else
    return @"unknown";
#endif
}

+ (NSString *)optimizationLevel {
    // Clang exposes only the class of optimisation, not the level: -O1/-O2/-O3
    // are indistinguishable here. Reporting "-O1+" is honest; inventing "-O3"
    // would be the kind of detail someone later trusts.
#if defined(__OPTIMIZE_SIZE__)
    return @"-Os/-Oz";
#elif defined(__OPTIMIZE__)
    return @"-O1+";
#else
    return @"-O0";
#endif
}

+ (BOOL)optimized {
#ifdef __OPTIMIZE__
    return YES;
#else
    return NO;
#endif
}

+ (BOOL)assertionsEnabled {
#ifdef NDEBUG
    return NO;
#else
    return YES;
#endif
}

+ (BOOL)simulator {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

+ (NSString *)fptnCommit {
    NSString *full = @FPTN_BUILD_COMMIT;
    return full.length > 7 ? [full substringToIndex:7] : full;
}

+ (NSString *)compiler {
#if defined(__clang_version__)
    return @__clang_version__;
#else
    return @"unknown";
#endif
}

+ (NSString *)buildTimestamp {
    return @(__DATE__ " " __TIME__);
}

+ (BOOL)performanceRepresentative {
    return FPTNBuildInfo.optimized && !FPTNBuildInfo.simulator;
}

+ (NSString *)summary {
    return [NSString stringWithFormat:@"%@ %@ · %@ · assertions %@ · fptn %@",
                     FPTNBuildInfo.configuration,
                     FPTNBuildInfo.optimizationLevel,
                     FPTNBuildInfo.platform,
                     FPTNBuildInfo.assertionsEnabled ? @"on" : @"off",
                     FPTNBuildInfo.fptnCommit];
}

@end

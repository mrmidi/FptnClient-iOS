/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#ifndef FPTN_BUILD_INFO_H
#define FPTN_BUILD_INFO_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Provenance of the native framework binary, captured from the preprocessor
/// when this file was compiled.
///
/// Deliberately NOT read from `fptn_native_lib.build-manifest.json`: that
/// sidecar travels separately from the binary, so a framework copied between
/// build directories carries a manifest describing a different build. These
/// values are compiled into the same binary they describe and cannot disagree
/// with it.
@interface FPTNBuildInfo : NSObject

/// CMake configuration the framework was built with ("Debug", "Release", ...).
/// Conan builds the fptn dependency with this same `build_type`, so it covers
/// the protocol library too, not just the Apple wrapper.
@property(class, nonatomic, readonly) NSString *configuration;

/// Build target as named by build_fptn_lib.sh ("ios-device", "macos", ...).
@property(class, nonatomic, readonly) NSString *target;

/// Effective platform, read from TargetConditionals rather than trusting the
/// build script's argument.
@property(class, nonatomic, readonly) NSString *platform;

/// The -O class the compiler was actually invoked with: "-O0", "-Os/-Oz" or
/// "-O1+". The exact level is not recoverable from predefined macros, so this
/// reports the class rather than inventing a precise number.
@property(class, nonatomic, readonly) NSString *optimizationLevel;

/// Whether any optimisation above -O0 was applied.
@property(class, nonatomic, readonly) BOOL optimized;

/// Whether assert() is live (NDEBUG undefined).
@property(class, nonatomic, readonly) BOOL assertionsEnabled;

/// Built against a simulator SDK.
@property(class, nonatomic, readonly) BOOL simulator;

/// Short commit of the FptnLib/fptn submodule this framework was built from.
@property(class, nonatomic, readonly) NSString *fptnCommit;

/// Compiler identity, for comparing two builds that otherwise look alike.
@property(class, nonatomic, readonly) NSString *compiler;

/// When this translation unit was compiled.
@property(class, nonatomic, readonly) NSString *buildTimestamp;

/// NO when a performance measurement taken against this binary cannot be
/// trusted: an unoptimised build, or the simulator. Check this before reading
/// any profile — at -O0 the template-heavy layers (asio, protobuf, yaff) are
/// inflated far more than the rest, which reorders the hot spots rather than
/// just scaling them.
@property(class, nonatomic, readonly) BOOL performanceRepresentative;

/// One line for logs and the settings screen, e.g.
/// "Debug -O0 · ios-simulator · assertions on · fptn 3fb5ff6".
@property(class, nonatomic, readonly) NSString *summary;

@end

NS_ASSUME_NONNULL_END

#endif  // FPTN_BUILD_INFO_H

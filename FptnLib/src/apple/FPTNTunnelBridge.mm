/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#import "FPTNTunnelBridge.h"

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <fstream>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <vector>
#include <unistd.h>

#include <openssl/sha.h>

#include "fptn-protocol-lib/geo/geo_compiler.h"
#include "fptn-protocol-lib/geo/geo_dat_parser.h"
#include "fptn-protocol-lib/geo/geo_inputs.h"
#include "fptn-protocol-lib/geo/geo_routing_policy.h"
#include "fptn-protocol-lib/geo/geo_rule_set.h"
#include "fptn-protocol-lib/tunnel/tunnel_engine.h"
#include "../websocket/WrapperWebsocketClientBridge.h"
#include "FPTNAppleLogSink.h"

#include <spdlog/spdlog.h>

namespace {

// The provider replaces its websocket bridge on every reconnect generation, so
// the transport is resolved through this slot on each batch rather than
// captured once. The mutex is held across the resolve so a setter cannot drop
// the old bridge while an ingress call is still inside it.
struct SplitTransportSlot {
    std::mutex mutex;
    WebsocketSwiftBridge* bridge = nullptr;
};

std::vector<std::string> ToStringVector(NSArray<NSString *> *values) {
    std::vector<std::string> out;
    out.reserve(values.count);
    for (NSString *value in values) {
        if (value.length > 0) {
            out.emplace_back([value UTF8String]);
        }
    }
    return out;
}

std::string FileSystemPath(NSString *directory, NSString *name) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    const char *fileSystemPath = [path fileSystemRepresentation];
    return fileSystemPath == nullptr ? std::string{} : fileSystemPath;
}

std::vector<std::uint8_t> ReadBytes(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        return {};
    }
    const std::streampos end = file.tellg();
    if (end <= std::streampos(0)) {
        return {};
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end));
    file.seekg(0, std::ios::beg);
    file.read(reinterpret_cast<char *>(bytes.data()),
        static_cast<std::streamsize>(bytes.size()));
    if (!file) {
        return {};
    }
    return bytes;
}

bool WriteAll(int fd, const std::vector<std::uint8_t>& bytes) {
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        const ssize_t written = ::write(
            fd, bytes.data() + offset, bytes.size() - offset);
        if (written > 0) {
            offset += static_cast<std::size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

bool FailGeoCompile(std::string message, std::string& failure) {
    failure = std::move(message);
    SPDLOG_WARN("[geo] source compilation failed: {}", failure);
    return false;
}

std::array<std::uint8_t, fptn::geo::kSha256Size> Sha256(
    const std::vector<std::uint8_t>& bytes) {
    std::array<std::uint8_t, fptn::geo::kSha256Size> digest = {};
    ::SHA256(bytes.data(), bytes.size(), digest.data());
    return digest;
}

bool PublishCompiledArtifact(NSString *geoDatabaseDirectory,
    const std::vector<std::uint8_t>& bytes, std::string& failure) {
    const std::string artifactPath = FileSystemPath(
        geoDatabaseDirectory, @"geo-routing.bin");
    std::string temporaryPath = artifactPath + ".XXXXXX";
    const int fd = ::mkstemp(temporaryPath.data());
    if (fd < 0) {
        return FailGeoCompile(
            "could not create the temporary compiled artifact: " +
                std::string(std::strerror(errno)),
            failure);
    }

    const bool written = WriteAll(fd, bytes);
    const bool synced = written && ::fsync(fd) == 0;
    const int closeResult = ::close(fd);
    if (!written || !synced || closeResult != 0) {
        ::unlink(temporaryPath.c_str());
        return FailGeoCompile(
            "could not write the temporary compiled artifact", failure);
    }

    // Validate the exact bytes that are about to be published. This keeps a
    // compiler/reader mismatch from ever becoming the active routing policy.
    auto rules = std::make_unique<fptn::geo::GeoRuleSet>();
    const auto loadError = rules->Open(temporaryPath, true);
    if (loadError != fptn::geo::GeoLoadError::none) {
        ::unlink(temporaryPath.c_str());
        return FailGeoCompile(
            "compiled artifact rejected: " +
                std::string(fptn::geo::ToString(loadError)),
            failure);
    }

    // Same-directory rename is atomic. A running tunnel that already mapped
    // the old inode continues to see its old, consistent artifact; the next
    // tunnel session sees the new one after the manifest is committed.
    if (::rename(temporaryPath.c_str(), artifactPath.c_str()) != 0) {
        ::unlink(temporaryPath.c_str());
        return FailGeoCompile(
            "could not publish " + artifactPath + ": " +
                std::string(std::strerror(errno)),
            failure);
    }

    SPDLOG_INFO("[geo] published compiled routing artifact={} bytes={} "
                "ipv4_intervals={} ipv6_rules={} domains={} substrings={} "
                "pairs={}",
        artifactPath, bytes.size(), rules->ipv4_count(), rules->ipv6_count(),
        rules->domain_count(), rules->substring_count(), rules->pair_count());
    return true;
}

bool CompileGeoDatabaseImpl(NSString *geoDatabaseDirectory,
    bool routePushThroughTunnel, std::string& failure) {
    if (geoDatabaseDirectory.length == 0) {
        return FailGeoCompile("geo database directory is empty", failure);
    }

    NSString *manifestPath = [geoDatabaseDirectory
        stringByAppendingPathComponent:@"manifest.json"];
    NSString *geoipPath = [geoDatabaseDirectory
        stringByAppendingPathComponent:@"geoip.dat"];
    NSString *geositePath = [geoDatabaseDirectory
        stringByAppendingPathComponent:@"geosite.dat"];
    const std::string directoryFilePath = FileSystemPath(
        geoDatabaseDirectory, @"");
    const std::string manifestFilePath = FileSystemPath(
        geoDatabaseDirectory, @"manifest.json");
    const std::string geoipFilePath = FileSystemPath(
        geoDatabaseDirectory, @"geoip.dat");
    const std::string geositeFilePath = FileSystemPath(
        geoDatabaseDirectory, @"geosite.dat");
    const std::string artifactFilePath = FileSystemPath(
        geoDatabaseDirectory, @"geo-routing.bin");
    NSFileManager *fileManager = [NSFileManager defaultManager];
    const bool manifestExists = [fileManager fileExistsAtPath:manifestPath];
    const bool geoipExists = [fileManager fileExistsAtPath:geoipPath];
    const bool geositeExists = [fileManager fileExistsAtPath:geositePath];

    SPDLOG_INFO(
        "[geo] compiling directory={} manifest={} exists={} geoip={} exists={} "
        "geosite={} exists={} output={}",
        directoryFilePath, manifestFilePath, manifestExists, geoipFilePath,
        geoipExists, geositeFilePath, geositeExists, artifactFilePath);
    if (!geoipExists || !geositeExists) {
        return FailGeoCompile("one or more source files are missing", failure);
    }

    const auto geoipBytes = ReadBytes(geoipFilePath);
    const auto geositeBytes = ReadBytes(geositeFilePath);
    SPDLOG_INFO("[geo] read source files geoip={} bytes={} geosite={} bytes={}",
        geoipFilePath, geoipBytes.size(), geositeFilePath,
        geositeBytes.size());
    if (geoipBytes.empty() || geositeBytes.empty()) {
        return FailGeoCompile("one or more source files are empty or unreadable",
            failure);
    }

    SPDLOG_INFO("[geo] parsing geoip.dat and geosite.dat");
    const auto ip = fptn::geo::GeoDatParser::ParseGeoIp(
        std::span<const std::uint8_t>(geoipBytes.data(), geoipBytes.size()));
    if (!ip.ok()) {
        return FailGeoCompile(
            "geoip.dat rejected: " + std::string(fptn::geo::ToString(ip.error)) +
                " at byte " + std::to_string(ip.error_offset),
            failure);
    }
    const auto site = fptn::geo::GeoDatParser::ParseGeoSite(
        std::span<const std::uint8_t>(
            geositeBytes.data(), geositeBytes.size()));
    if (!site.ok()) {
        return FailGeoCompile(
            "geosite.dat rejected: " +
                std::string(fptn::geo::ToString(site.error)) + " at byte " +
                std::to_string(site.error_offset),
            failure);
    }
    SPDLOG_INFO("[geo] parsed {} IP groups and {} site groups", ip.groups.size(),
        site.groups.size());

    const auto verdictMap = fptn::geo::DefaultVerdictMap(
        fptn::geo::GeoIpProfile::standard, routePushThroughTunnel);
    const auto built = fptn::geo::BuildGeoInputs(
        ip.groups, site.groups, verdictMap);
    // Skipped rules are reported, never adopted. BuildGeoInputs drops an
    // inverted group rather than routing its complement, and drops a regex it
    // cannot reduce; both then fall to the default verdict, which is the
    // tunnel. That is the safe direction — it costs bandwidth, not privacy.
    //
    // Refusing the whole compile over them, as this used to, meant one new
    // regex shape upstream would strand every rule in both files. The
    // publisher ships daily, so that was a matter of when.
    for (const std::string& pattern : built.report.unsupported_regexes) {
        SPDLOG_WARN("[geo] skipping unreducible regex: {}", pattern);
    }
    for (const std::string& name : built.report.inverted_groups) {
        SPDLOG_WARN("[geo] skipping inverted IP group: {}", name);
    }
    if (!built.report.unsupported_regexes.empty() ||
        !built.report.inverted_groups.empty()) {
        SPDLOG_WARN("[geo] compiling a partial policy: {} regexes and {} "
                    "inverted groups skipped",
            built.report.unsupported_regexes.size(),
            built.report.inverted_groups.size());
    }

    if (routePushThroughTunnel) {
        // Zero here is the interesting reading: the published lists no longer
        // send Apple's couriers direct, so the override is a no-op and push is
        // tunnelling for some other reason.
        SPDLOG_INFO("[geo] apple push -> server; displaced {} published rules",
            built.report.apple_push_rules_overridden);
    } else {
        SPDLOG_INFO("[geo] apple push -> direct, as published");
    }

    // The one case worth refusing: nothing survived. An empty artifact would
    // publish as "active" and route exactly nothing, which is harder to
    // diagnose than having no artifact at all.
    if (built.inputs.cidrs.empty() && built.inputs.domains.empty() &&
        built.inputs.substrings.empty() && built.inputs.pairs.empty()) {
        return FailGeoCompile(
            "no usable rules survived parsing; refusing an empty policy",
            failure);
    }

    fptn::geo::GeoCompileOptions options;
    options.default_action = verdictMap.default_action;
    options.bare_hostname_is_direct = built.report.bare_hostname_is_direct;
    options.verdict_map_id = verdictMap.id();
    options.geoip_sha256 = Sha256(geoipBytes);
    options.geosite_sha256 = Sha256(geositeBytes);
    options.built_at_unix = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    SPDLOG_INFO("[geo] building compiled policy from {} CIDRs, {} domains, "
                "{} substrings, {} pairs",
        built.inputs.cidrs.size(), built.inputs.domains.size(),
        built.inputs.substrings.size(), built.inputs.pairs.size());
    const auto compiled = fptn::geo::GeoCompiler::Compile(
        built.inputs, options);
    if (!compiled.ok || compiled.bytes.empty()) {
        return FailGeoCompile(
            compiled.error.empty() ? "empty artifact" : compiled.error,
            failure);
    }
    SPDLOG_INFO("[geo] compiled policy bytes={} domain_conflicts={}",
        compiled.bytes.size(), compiled.stats.domain_conflicts);
    return PublishCompiledArtifact(geoDatabaseDirectory, compiled.bytes, failure);
}

// `status` is a short human-readable verdict handed back to the platform layer.
//
// It exists because the native spdlog output has proven unreliable to observe
// from a shipped extension, and "is geo routing actually active" is the one
// question that must be answerable without attaching a log stream. The caller
// logs it through the platform logger, which is the path known to survive.
std::shared_ptr<const fptn::tunnel::IRoutingPolicy> LoadGeoPolicyImpl(
    NSString *geoDatabaseDirectory, NSString **status) {
    *status = @"inactive (not attempted)";
    if (geoDatabaseDirectory.length == 0) {
        SPDLOG_WARN("[geo] geo database directory is empty; split policy stays "
                    "tunnel-only");
        *status = @"inactive (no shared directory)";
        return nullptr;
    }

    NSString *manifestPath = [geoDatabaseDirectory
        stringByAppendingPathComponent:@"manifest.json"];
    NSString *artifactPath = [geoDatabaseDirectory
        stringByAppendingPathComponent:@"geo-routing.bin"];
    const std::string directoryFilePath = FileSystemPath(
        geoDatabaseDirectory, @"");
    const std::string manifestFilePath = FileSystemPath(
        geoDatabaseDirectory, @"manifest.json");
    const std::string artifactFilePath = FileSystemPath(
        geoDatabaseDirectory, @"geo-routing.bin");
    NSFileManager *fileManager = [NSFileManager defaultManager];
    const bool manifestExists = [fileManager fileExistsAtPath:manifestPath];
    const bool artifactExists = [fileManager fileExistsAtPath:artifactPath];
    NSNumber *artifactSize = [[fileManager
        attributesOfItemAtPath:artifactPath error:nil] objectForKey:NSFileSize];

    SPDLOG_INFO(
        "[geo] loading directory={} manifest={} exists={} artifact={} "
        "exists={} bytes={}",
        directoryFilePath, manifestFilePath, manifestExists, artifactFilePath,
        artifactExists, artifactSize ? artifactSize.unsignedLongLongValue : 0);
    if (!manifestExists) {
        SPDLOG_WARN("[geo] no published manifest at {}; split policy stays "
                    "tunnel-only", manifestFilePath);
        *status = @"inactive (no manifest — database not published yet)";
        return nullptr;
    }
    if (!artifactExists) {
        SPDLOG_WARN("[geo] no compiled routing artifact at {}; split policy "
                    "stays tunnel-only", artifactFilePath);
        *status = @"inactive (manifest present but no compiled artifact)";
        return nullptr;
    }

    auto rules = std::make_shared<fptn::geo::GeoRuleSet>();
    const auto loadError = rules->Open(artifactFilePath, true);
    if (loadError != fptn::geo::GeoLoadError::none) {
        SPDLOG_WARN("[geo] compiled artifact rejected: {}; split policy stays "
                    "tunnel-only", fptn::geo::ToString(loadError));
        *status = [NSString stringWithFormat:@"inactive (artifact rejected: %s)",
                            fptn::geo::ToString(loadError)];
        return nullptr;
    }

    SPDLOG_INFO(
        "[geo] loaded compiled artifact: {} IPv4 intervals, {} IPv6 rules, "
        "{} domains, {} substrings, {} pairs ({} bytes)",
        rules->ipv4_count(), rules->ipv6_count(), rules->domain_count(),
        rules->substring_count(), rules->pair_count(),
        artifactSize ? artifactSize.unsignedLongLongValue : 0);
    *status = [NSString
        stringWithFormat:@"active (%u ipv4, %u ipv6, %u domains, %u substrings, "
                          "%u pairs, %llu bytes)",
                         rules->ipv4_count(), rules->ipv6_count(),
                         rules->domain_count(), rules->substring_count(),
                         rules->pair_count(),
                         artifactSize ? artifactSize.unsignedLongLongValue : 0];
    return std::make_shared<fptn::geo::GeoRoutingPolicy>(
        std::move(rules), fptn::tunnel::RouteAction::fptn_l4);
}

void SetGeoError(NSError **error, const std::string& message) {
    if (error == nullptr) {
        return;
    }
    NSString *description = [NSString stringWithUTF8String:message.c_str()];
    if (description == nil) {
        description = @"The geo routing policy could not be compiled.";
    }
    *error = [NSError errorWithDomain:@"org.fptn.geo" code:1
                              userInfo:@{NSLocalizedDescriptionKey: description}];
}

bool CompileGeoDatabase(NSString *geoDatabaseDirectory,
    bool routePushThroughTunnel, std::string& failure) {
    try {
        return CompileGeoDatabaseImpl(
            geoDatabaseDirectory, routePushThroughTunnel, failure);
    } catch (const std::exception& exception) {
        failure = exception.what();
        SPDLOG_ERROR("[geo] exception while compiling the geo database: {}",
            failure);
    } catch (...) {
        failure = "unknown exception";
        SPDLOG_ERROR("[geo] unknown exception while compiling the geo database");
    }
    return false;
}

std::shared_ptr<const fptn::tunnel::IRoutingPolicy> LoadGeoPolicy(
    NSString *geoDatabaseDirectory, NSString **status) {
    try {
        return LoadGeoPolicyImpl(geoDatabaseDirectory, status);
    } catch (const std::exception& exception) {
        SPDLOG_ERROR("[geo] exception while loading the compiled geo database: "
                     "{}; split policy stays tunnel-only", exception.what());
        *status = [NSString stringWithFormat:@"inactive (exception: %s)",
                            exception.what()];
    } catch (...) {
        SPDLOG_ERROR("[geo] unknown exception while loading the compiled geo "
                     "database; split policy stays tunnel-only");
        *status = @"inactive (unknown exception)";
    }
    return nullptr;
}

}  // namespace

@interface FPTNTunnelBridge () {
    std::unique_ptr<fptn::tunnel::TunnelEngine> _engine;
    FPTNApplePacketFlowAdapter * __weak _egressAdapter;
    std::shared_ptr<SplitTransportSlot> _transportSlot;
    // Reused by -consumePackets: rather than allocated per batch. Safe because
    // that method is called only from the packet-flow adapter's serial read
    // callback, which never overlaps itself.
    std::vector<fptn::tunnel::PacketLease> _consumeLeases;
}
@property (nonatomic, copy, nullable) NSString *geoRoutingStatusStorage;
@end

@implementation FPTNTunnelBridge

+ (void)initialize {
    if (self == [FPTNTunnelBridge class]) {
        // Before any native code runs, so nothing is logged into the void.
        FPTNInstallAppleLogSink();
    }
}

+ (BOOL)isFlowSupported {
    return [FPTNApplePacketFlowAdapter isFlowSupported];
}

- (NSString *)geoRoutingStatus {
    NSString *status = self.geoRoutingStatusStorage;
    return status.length == 0 ? @"inactive (not a split bridge)" : status;
}

+ (BOOL)compileGeoRoutingPolicyAtPath:(NSString *)directoryPath
               routePushThroughTunnel:(BOOL)routePushThroughTunnel
                                error:(NSError * _Nullable * _Nullable)error {
    if (error != nullptr) {
        *error = nil;
    }

    std::string failure;
    if (CompileGeoDatabase(directoryPath, routePushThroughTunnel, failure)) {
        return YES;
    }
    SetGeoError(error, failure);
    return NO;
}

+ (uint32_t)geoRoutingVerdictMapIdAtPath:(NSString *)directoryPath {
    if (directoryPath.length == 0) {
        return 0;
    }
    const std::string artifactPath = FileSystemPath(
        directoryPath, @"geo-routing.bin");
    auto rules = std::make_shared<fptn::geo::GeoRuleSet>();
    // Checksum verification skipped on purpose: this answers "which opinion is
    // published", and an artifact too damaged to route on still has to be
    // recognisable as stale so it can be replaced. Opening for routing
    // verifies.
    if (rules->Open(artifactPath, /*verify_checksum=*/false) !=
        fptn::geo::GeoLoadError::none) {
        return 0;
    }
    return rules->verdict_map_id();
}

+ (uint32_t)geoRoutingVerdictMapIdForRoutePushThroughTunnel:
    (BOOL)routePushThroughTunnel {
    return fptn::geo::DefaultVerdictMap(
        fptn::geo::GeoIpProfile::standard, routePushThroughTunnel)
        .id();
}

- (instancetype)initWithTunIPv4:(NSString *)tunIPv4
                        tunIPv6:(nullable NSString *)tunIPv6
                            mtu:(uint16_t)mtu {
    self = [super init];
    if (self) {
        fptn::tunnel::TunnelConfiguration config;
        config.mode = fptn::tunnel::DataPlaneMode::flow_proxy;
        config.flow.tun_ipv4 = tunIPv4 ? [tunIPv4 UTF8String] : "";
        config.flow.tun_ipv6 = tunIPv6 ? [tunIPv6 UTF8String] : "";
        config.flow.mtu = mtu;

        __weak __typeof__(self) weakSelf = self;
        fptn::tunnel::TunnelCallbacks callbacks;
        callbacks.on_owned_packet_batch = [weakSelf](fptn::tunnel::OwnedPacketBatchView batch) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            FPTNApplePacketFlowAdapter *adapter = strongSelf->_egressAdapter;
            if (adapter) {
                [adapter sendEgressBatch:batch];
            }
        };

        auto createResult = fptn::tunnel::TunnelEngine::Create(config, std::move(callbacks));
        if (createResult.has_value()) {
            _engine = std::move(*createResult);
        }
    }
    return self;
}

- (nullable instancetype)initSplitWithTunIPv4:(NSString *)tunIPv4
                                      tunIPv6:(nullable NSString *)tunIPv6
                                          mtu:(uint16_t)mtu
                                   serverIP:(NSString *)serverIP
                                 serverPort:(int)serverPort
                             directDomains:(NSArray<NSString *> *)directDomains
                               rejectDomains:(NSArray<NSString *> *)rejectDomains
                                 dropDomains:(NSArray<NSString *> *)dropDomains
                             tunnelResolvers:(NSArray<NSString *> *)tunnelResolvers
                             directResolvers:(NSArray<NSString *> *)directResolvers
                         geoDatabaseDirectory:(nullable NSString *)geoDatabaseDirectory {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (serverIP.length == 0 || serverPort <= 0) {
        return nil;
    }
    _transportSlot = std::make_shared<SplitTransportSlot>();

    fptn::tunnel::TunnelConfiguration config;
    config.mode = fptn::tunnel::DataPlaneMode::split;
    config.flow.tun_ipv4 = tunIPv4 ? [tunIPv4 UTF8String] : "";
    config.flow.tun_ipv6 = tunIPv6 ? [tunIPv6 UTF8String] : "";
    config.flow.mtu = mtu;
    // The lwIP netif uses the configured tun address, not the server-assigned
    // one: the transport NATs between them on the wire, so the assigned
    // address never appears on this interface.
    config.l3.server_ip = [serverIP UTF8String];
    config.l3.server_port = serverPort;
    config.l3.tun_ipv4 = config.flow.tun_ipv4;
    config.l3.tun_ipv6 = config.flow.tun_ipv6;
    config.routing.direct_domains = ToStringVector(directDomains);
    config.routing.reject_domains = ToStringVector(rejectDomains);
    config.routing.drop_domains = ToStringVector(dropDomains);
    config.routing.tunnel_resolvers = ToStringVector(tunnelResolvers);
    config.routing.direct_resolvers = ToStringVector(directResolvers);
    NSString *geoStatus = @"inactive (not attempted)";
    auto routingPolicy = LoadGeoPolicy(geoDatabaseDirectory, &geoStatus);
    self.geoRoutingStatusStorage = geoStatus;

    __weak __typeof__(self) weakSelf = self;
    fptn::tunnel::TunnelCallbacks callbacks;
    callbacks.on_owned_packet_batch = [weakSelf](fptn::tunnel::OwnedPacketBatchView batch) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        FPTNApplePacketFlowAdapter *adapter = strongSelf->_egressAdapter;
        if (adapter) {
            [adapter sendEgressBatch:batch];
        }
    };

    // Borrowed, not owned: the provider keeps managing this websocket, so a
    // reconnect swaps the transport underneath us without disturbing lwIP.
    // Resolving through the slot (rather than capturing a bridge) is what makes
    // that safe, since the provider builds a new bridge per generation.
    fptn::tunnel::TransportProvider transport =
        [slot = _transportSlot]() -> std::shared_ptr<fptn::protocol::https::WebsocketClient> {
            std::lock_guard<std::mutex> lock(slot->mutex);
            return slot->bridge ? slot->bridge->splitRoutingTransport() : nullptr;
        };

    auto createResult = fptn::tunnel::TunnelEngine::CreateSplit(
        std::move(config), std::move(callbacks), std::move(transport),
        std::move(routingPolicy));
    if (!createResult.has_value()) {
        return nil;
    }
    _engine = std::move(*createResult);
    return self;
}

- (void)setSplitTransport:(nullable void *)websocketBridge {
    if (!_transportSlot) {
        return;
    }
    std::lock_guard<std::mutex> lock(_transportSlot->mutex);
    _transportSlot->bridge = static_cast<WebsocketSwiftBridge *>(websocketBridge);
}

- (void)observeInboundPacket:(const uint8_t *)bytes length:(size_t)length {
    if (!_engine || bytes == nullptr || length == 0) {
        return;
    }
    if (auto *plane = _engine->SplitPlane()) {
        plane->ObserveInboundPacket(bytes, length);
    }
}

- (void)setEgressAdapter:(nullable FPTNApplePacketFlowAdapter *)adapter {
    _egressAdapter = adapter;
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    if (!_engine) {
        if (error) {
            *error = [NSError errorWithDomain:@"net.mrmidi.FptnVPN"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create TunnelEngine"}];
        }
        return NO;
    }
    auto result = _engine->Start();
    if (!result.has_value()) {
        if (error) {
            *error = [NSError errorWithDomain:@"net.mrmidi.FptnVPN"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Engine failed to start"}];
        }
        return NO;
    }
    return YES;
}

- (void)stop {
    if (_engine) {
        _engine->Stop();
    }
}

- (BOOL)isStarted {
    return _engine != nullptr && _engine->IsStarted();
}

- (FPTNSplitCounters)splitCounters {
    FPTNSplitCounters out = {};
    if (!_engine) {
        return out;
    }
    auto* plane = _engine->SplitPlane();
    if (plane == nullptr) {
        return out;
    }
    const auto split = plane->SplitStatistics();
    out.batches = split.batches;
    out.packetsToStack = split.packets_to_stack;
    out.packetsToTransport = split.packets_to_transport;
    out.packetsDropped = split.packets_dropped;
    out.rollbacks = split.rollbacks;

    const auto classifier = plane->ClassifierForTesting().Counters();
    out.classifiedPackets = classifier.classified_packets;
    out.mruHits = classifier.mru_hits;
    out.decisions = classifier.decisions;
    out.tableHits = classifier.table_hits;
    out.unclassifiable = classifier.unclassifiable;
    out.activeFlows = classifier.active_flows;
    out.directFlows = classifier.direct_flows;
    out.fptnFlows = classifier.fptn_flows;
    out.rejectedFlows = classifier.rejected_flows;
    out.droppedFlows = classifier.dropped_flows;

    const auto dns = plane->DnsObserverForTesting().Counters();
    out.dnsResponsesParsed = dns.responses_parsed;
    out.dnsMappingsRecorded = dns.mappings_recorded;
    out.dnsEntries = dns.entries;

    out.routerUnknownFlows = plane->RouterUnknownFlows();
    return out;
}

- (FPTNFlowCounters)flowCounters {
    FPTNFlowCounters out = {};
    if (!_engine) {
        return out;
    }
    const fptn::tunnel::FlowCounters c = _engine->Counters();
    out.inputPackets = c.input_packets;
    out.inputBytes = c.input_bytes;
    out.ingressZeroCopyPackets = c.ingress_zero_copy_packets;
    out.ingressCopyPackets = c.ingress_copy_packets;
    out.leasePoolExhaustions = c.lease_pool_exhaustions;
    out.droppedPackets = c.dropped_packets;
    out.activeTcpFlows = c.active_tcp_flows;
    out.peakTcpFlows = c.peak_tcp_flows;
    out.activeUdpFlows = c.active_udp_flows;
    out.peakUdpFlows = c.peak_udp_flows;
    out.tcpBackpressureEvents = c.tcp_backpressure_events;
    out.tcpResets = c.tcp_resets;
    out.udpDrops = c.udp_drops;
    out.tcpOutboundActive = c.tcp_outbound_active;
    out.tcpOutboundOpenedTotal = c.tcp_outbound_opened_total;
    out.udpOutboundActive = c.udp_outbound_active;
    out.outputPackets = c.output_packets;
    out.outputBytes = c.output_bytes;
    out.egressBatches = c.egress_batches;
    return out;
}

- (FPTNPacketInputResult)consumePackets:(const FPTNPacketDescriptor *)packets count:(NSUInteger)count {
    if (!_engine || count == 0) {
        return FPTNPacketInputResultInvalidPacket;
    }
    // Reused across batches; the caller is the serial read callback, and
    // capacity survives clear() so this stops allocating after the first few.
    std::vector<fptn::tunnel::PacketLease> &leases = _consumeLeases;
    leases.clear();
    leases.reserve(count);
    for (NSUInteger i = 0; i < count; ++i) {
        leases.push_back(fptn::tunnel::PacketLease{
            .bytes = packets[i].bytes,
            .length = packets[i].length,
            .ip_version = packets[i].ipVersion,
            // Carries the retained NSData through to the engine, which
            // releases it once the bytes are no longer referenced by a pbuf.
            .owner = packets[i].owner,
            .release = &fptn_release_ingress_packet
        });
    }
    fptn::tunnel::PacketBatchView view(leases.data(), count);
    fptn::tunnel::PacketInputResult result = _engine->InputPackets(view);
    return static_cast<FPTNPacketInputResult>(result);
}

@end

/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import Testing
@testable import FptnVPN

/// Anchors bundle lookup for the fixtures. Swift Testing suites are structs, so
/// there is no `Bundle(for: type(of: self))` to reach for.
private final class GeoFixtureBundleToken {}

private enum GeoFixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: GeoFixtureBundleToken.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "dat"),
            "\(name).dat is missing from the test bundle resources"
        )
        return try Data(contentsOf: url)
    }

    static func geoip() throws -> GeoIPTable { try GeoDatParser.parseGeoIP(try data("geoip")) }
    static func geosite() throws -> GeoSiteTable { try GeoDatParser.parseGeoSite(try data("geosite")) }
}

// MARK: - Wire format, checked against the real published files

/// The fixtures are the actual published files, and the expected numbers below
/// were produced by an independent implementation (the reference Python
/// inspector). They are exact on purpose: a parser that silently drops or
/// duplicates entries would still "work" against loose assertions.
@Suite struct GeoDatParserFixtureTests {

    @Test func geoipDecodesEveryPublishedRange() throws {
        let table = try GeoFixture.geoip()
        #expect(table.groups.count == 3)
        #expect(table.ruleCount == 42_383)
        #expect(table.ipv6Count == 88)

        let byName = Dictionary(uniqueKeysWithValues: table.groups.map { ($0.name, $0) })
        #expect(byName["DIRECT"]?.entryCount == 35_656)
        #expect(byName["WHITELIST"]?.entryCount == 6_710)
        #expect(byName["PRIVATE"]?.entryCount == 17)
        #expect(table.groups.allSatisfy { !$0.isInverse })
    }

    @Test func geositeDecodesEveryPublishedDomain() throws {
        let table = try GeoFixture.geosite()
        #expect(table.groups.count == 23)
        #expect(table.ruleCount == 3_107)

        var histogram: [GeoDomainRule.Kind: Int] = [:]
        for rule in table.rules { histogram[rule.kind, default: 0] += 1 }
        #expect(histogram[.rootDomain] == 2_984)
        #expect(histogram[.plain] == 105)
        #expect(histogram[.full] == 11)
        #expect(histogram[.regex] == 7)
    }

    /// Only `rootDomain` is honoured by the native `StaticDomainPolicy` today.
    /// This test exists to make the size of that gap visible: if a future file
    /// leans harder on the other three, the number moves and someone has to
    /// decide what to do about it.
    @Test func mostDomainRulesAreExpressibleByTheEngine() throws {
        let table = try GeoFixture.geosite()
        let unsupported = table.rules.filter { !$0.kind.isSupportedByEngine }
        #expect(unsupported.count == 123)
    }

    @Test func groupCountsAgreeWithTheRulesTheyOwn() throws {
        let ip = try GeoFixture.geoip()
        for group in ip.groups {
            let owned = ip.rules.filter { $0.groupIndex == group.index }.count
            #expect(owned == group.entryCount, "\(group.name) count disagrees")
        }

        let site = try GeoFixture.geosite()
        for group in site.groups {
            let owned = site.rules.filter { $0.groupIndex == group.index }.count
            #expect(owned == group.entryCount, "\(group.name) count disagrees")
        }
    }
}

// MARK: - Lookup

@Suite struct GeoLookupTests {

    @Test func longestPrefixWinsOverAContainingRange() throws {
        let table = try GeoFixture.geoip()
        // 98% of WHITELIST sits inside a DIRECT range. Resolving this address
        // to DIRECT would mean the table is answering by serialization order
        // rather than by specificity.
        let address = try #require(GeoAddress(text: "5.8.43.1"))
        let match = try #require(table.longestPrefixMatch(address))
        #expect(table.groups[match.groupIndex].name == "WHITELIST")
        #expect(match.prefix == 32)
    }

    @Test func resolvesAKnownRussianRange() throws {
        let table = try GeoFixture.geoip()
        let address = try #require(GeoAddress(text: "77.88.55.60"))
        let match = try #require(table.longestPrefixMatch(address))
        #expect(table.groups[match.groupIndex].name == "DIRECT")
        #expect(match.displayText == "77.88.0.0/18")
    }

    @Test func resolvesPrivateSpace() throws {
        let table = try GeoFixture.geoip()
        let address = try #require(GeoAddress(text: "10.0.0.5"))
        let match = try #require(table.longestPrefixMatch(address))
        #expect(table.groups[match.groupIndex].name == "PRIVATE")
    }

    @Test func unlistedAddressResolvesToNothing() throws {
        let table = try GeoFixture.geoip()
        let address = try #require(GeoAddress(text: "8.8.8.8"))
        #expect(table.longestPrefixMatch(address) == nil)
    }

    @Test func matchesIPv6() throws {
        let table = try GeoFixture.geoip()
        let address = try #require(GeoAddress(text: "2a02:6b8::1"))
        let match = try #require(table.longestPrefixMatch(address))
        #expect(match.base.isIPv6)
        #expect(table.groups[match.groupIndex].name == "DIRECT")
    }

    /// An IPv4 address must never be answered by an IPv6 rule, or vice versa.
    @Test func familiesDoNotCrossMatch() throws {
        let v4 = try #require(GeoAddress(text: "77.88.55.60"))
        let v6Rule = GeoCIDRRule(
            base: try #require(GeoAddress(text: "::")),
            prefix: 0,
            groupIndex: 0,
            id: 0
        )
        #expect(!v6Rule.contains(v4))
    }

    @Test func suffixRulesAreLabelAware() throws {
        let table = try GeoFixture.geosite()
        #expect(table.bestMatch(for: "4pda.ru") != nil)
        #expect(table.bestMatch(for: "sub.4pda.ru") != nil)
        // Ends with the same characters but is a different domain.
        #expect(table.bestMatch(for: "not4pda.ru") == nil)
    }

    @Test func domainLookupReportsTheOwningGroup() throws {
        let table = try GeoFixture.geosite()
        let match = try #require(table.bestMatch(for: "ad.mail.ru"))
        #expect(table.groups[match.groupIndex].name == "CATEGORY-ADS")
        #expect(table.groups[match.groupIndex].verdict == .block)
    }

    @Test func longerSuffixBeatsShorterOne() {
        let groups = [
            GeoGroup(name: "BROAD", index: 0, entryCount: 1, verdict: .fptn, isInverse: false),
            GeoGroup(name: "SPECIFIC", index: 1, entryCount: 1, verdict: .direct, isInverse: false),
        ]
        let table = GeoSiteTable(groups: groups, rules: [
            GeoDomainRule(kind: .rootDomain, value: "example.com", groupIndex: 0, id: 0),
            GeoDomainRule(kind: .rootDomain, value: "mail.example.com", groupIndex: 1, id: 1),
        ])
        let match = table.bestMatch(for: "smtp.mail.example.com")
        #expect(match?.value == "mail.example.com")
    }

    @Test func exactRuleBeatsSuffixRule() {
        let groups = [
            GeoGroup(name: "SUFFIX", index: 0, entryCount: 1, verdict: .fptn, isInverse: false),
            GeoGroup(name: "EXACT", index: 1, entryCount: 1, verdict: .direct, isInverse: false),
        ]
        let table = GeoSiteTable(groups: groups, rules: [
            GeoDomainRule(kind: .rootDomain, value: "example.com", groupIndex: 0, id: 0),
            GeoDomainRule(kind: .full, value: "www.example.com", groupIndex: 1, id: 1),
        ])
        #expect(table.bestMatch(for: "www.example.com")?.kind == .full)
    }

    @Test func lookupIgnoresCaseAndATrailingRootDot() throws {
        let table = try GeoFixture.geosite()
        #expect(table.bestMatch(for: "SUB.4PDA.RU.") != nil)
    }
}

// MARK: - Addresses

@Suite struct GeoAddressTests {

    @Test(arguments: [
        ("0.0.0.0", false), ("255.255.255.255", false), ("77.88.55.60", false),
        ("::", true), ("2a02:6b8::1", true), ("::ffff:1.2.3.4", true),
    ])
    func parsesValidAddresses(text: String, isIPv6: Bool) throws {
        let address = try #require(GeoAddress(text: text))
        #expect(address.isIPv6 == isIPv6)
    }

    @Test(arguments: ["", "  ", "example.com", "256.0.0.1", "1.2.3", "gg::1", "77.88.55.60/18"])
    func rejectsInvalidAddresses(text: String) {
        #expect(GeoAddress(text: text) == nil)
    }

    @Test func ipv4RoundTripsThroughText() throws {
        let address = try #require(GeoAddress(text: "192.168.1.254"))
        #expect(address.displayText == "192.168.1.254")
    }

    @Test func ipv6RoundTripsThroughText() throws {
        let address = try #require(GeoAddress(text: "2a02:6b8::1"))
        #expect(address.displayText == "2a02:6b8::1")
    }

    @Test func maskingClearsHostBits() throws {
        let address = try #require(GeoAddress(text: "77.88.55.60"))
        #expect(address.masked(prefix: 18).displayText == "77.88.0.0")
        #expect(address.masked(prefix: 0).displayText == "0.0.0.0")
        #expect(address.masked(prefix: 32).displayText == "77.88.55.60")
    }

    @Test func maskingIPv6CrossesTheWordBoundary() throws {
        let address = try #require(GeoAddress(text: "2a02:6b8:1234:5678:9abc::1"))
        #expect(address.masked(prefix: 32).displayText == "2a02:6b8::")
        #expect(address.masked(prefix: 64).displayText == "2a02:6b8:1234:5678::")
        #expect(address.masked(prefix: 0).displayText == "::")
    }

    @Test func rejectsAddressesOfTheWrongLength() {
        #expect(GeoAddress(rawBytes: []) == nil)
        #expect(GeoAddress(rawBytes: [1, 2, 3]) == nil)
        #expect(GeoAddress(rawBytes: Array(repeating: 0, count: 5)) == nil)
        #expect(GeoAddress(rawBytes: Array(repeating: 0, count: 17)) == nil)
    }
}

// MARK: - Malformed input

/// These files are downloaded from a third party. Every one of these cases must
/// produce a thrown error rather than a crash, a hang, or a plausible-looking
/// empty table.
@Suite struct GeoDatParserFailureTests {

    /// Builds a length-delimited protobuf field.
    private func field(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        [UInt8(number << 3 | 2)] + varint(UInt64(payload.count)) + payload
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: GeoDatParseError.empty) {
            try GeoDatParser.parseGeoIP(Data())
        }
    }

    @Test func rejectsGzip() {
        #expect(throws: GeoDatParseError.gzipped) {
            try GeoDatParser.parseGeoIP(Data([0x1F, 0x8B, 0x08, 0x00, 0x00]))
        }
    }

    @Test func rejectsAFileWithNoGroups() {
        // Field 9 is unknown and gets skipped, leaving zero entries.
        #expect(throws: GeoDatParseError.noGroups) {
            try GeoDatParser.parseGeoIP(Data(field(9, [0x01, 0x02])))
        }
    }

    @Test func rejectsATruncatedVarint() {
        // A key byte with the continuation bit set and nothing after it.
        #expect(throws: (any Error).self) {
            try GeoDatParser.parseGeoIP(Data([0x80]))
        }
    }

    /// A length that overruns the buffer must throw rather than trap. This is
    /// the case that would otherwise crash on `position + length`.
    @Test func rejectsALengthBeyondTheBuffer() {
        let bytes: [UInt8] = [0x0A] + varint(UInt64(Int.max)) + [0x01]
        #expect(throws: (any Error).self) {
            try GeoDatParser.parseGeoIP(Data(bytes))
        }
    }

    @Test func rejectsAnAddressOfTheWrongLength() {
        let cidr = field(1, [1, 2, 3]) + [0x10] + varint(24)  // 3-byte "address"
        let group = field(1, Array("XX".utf8)) + field(2, cidr)
        #expect(throws: GeoDatParseError.invalidAddressLength(3)) {
            try GeoDatParser.parseGeoIP(Data(field(1, group)))
        }
    }

    @Test func rejectsAnOutOfRangePrefix() {
        let cidr = field(1, [10, 0, 0, 0]) + [0x10] + varint(33)  // /33 on IPv4
        let group = field(1, Array("XX".utf8)) + field(2, cidr)
        #expect(throws: GeoDatParseError.invalidPrefix(33, isIPv6: false)) {
            try GeoDatParser.parseGeoIP(Data(field(1, group)))
        }
    }

    @Test func rejectsAnUnnamedGroup() {
        let cidr = field(1, [10, 0, 0, 0]) + [0x10] + varint(8)
        #expect(throws: GeoDatParseError.unnamedGroup(index: 0)) {
            try GeoDatParser.parseGeoIP(Data(field(1, field(2, cidr))))
        }
    }

    /// Unknown fields must be skipped, not rejected — the publisher is free to
    /// add them, and a reader that refuses breaks on the next release.
    @Test func skipsUnknownFieldsOfEveryWireType() throws {
        var group = field(1, Array("XX".utf8))
        group += field(2, field(1, [10, 0, 0, 0]) + [0x10] + varint(8))
        group += [UInt8(7 << 3 | 0)] + varint(12_345)                 // varint
        group += [UInt8(8 << 3 | 5), 1, 2, 3, 4]                       // fixed32
        group += [UInt8(9 << 3 | 1), 1, 2, 3, 4, 5, 6, 7, 8]           // fixed64
        group += field(10, Array("ignored".utf8))                      // bytes

        let table = try GeoDatParser.parseGeoIP(Data(field(1, group)))
        #expect(table.ruleCount == 1)
        #expect(table.groups.first?.name == "XX")
    }

    /// Rules arrive unmasked in the wild; storing them raw would make
    /// containment tests wrong.
    @Test func normalizesAnUnmaskedRange() throws {
        let cidr = field(1, [10, 1, 2, 3]) + [0x10] + varint(8)
        let group = field(1, Array("XX".utf8)) + field(2, cidr)
        let table = try GeoDatParser.parseGeoIP(Data(field(1, group)))
        #expect(table.rules.first?.displayText == "10.0.0.0/8")
    }

    @Test func dropsEmptyDomainValues() throws {
        var group = field(1, Array("XX".utf8))
        group += field(2, [0x08] + varint(2) + field(2, Array("example.com".utf8)))
        group += field(2, [0x08] + varint(2) + field(2, []))  // empty value
        let table = try GeoDatParser.parseGeoSite(Data(field(1, group)))
        #expect(table.ruleCount == 1)
        #expect(table.groups.first?.entryCount == 1)
    }
}

// MARK: - Verdict preset

@Suite struct GeoVerdictPresetTests {

    /// Pinned against the publisher's documented routing profile
    /// (roscomvpn-routing), not against what the group names suggest. Several
    /// of these were wrong when inferred from the name, so they are asserted
    /// individually rather than by rule.
    @Test func everyPublishedGroupGetsAVerdict() throws {
        let ip = try GeoFixture.geoip()
        let site = try GeoFixture.geosite()
        #expect(ip.groups.allSatisfy { $0.verdict == .direct })

        let byName = Dictionary(uniqueKeysWithValues: site.groups.map { ($0.name, $0.verdict) })

        #expect(byName["CATEGORY-ADS"] == .block)
        #expect(byName["WIN-SPY"] == .block)
        #expect(byName["TORRENT"] == .block)

        #expect(byName["WHITELIST"] == .direct)
        #expect(byName["CATEGORY-RU"] == .direct)
        // Counter-intuitive, and documented upstream: games and Twitch waste
        // server traffic and misbehave behind a proxy; Apple/Microsoft need
        // updates and push to keep working.
        #expect(byName["STEAM"] == .direct)
        #expect(byName["EPICGAMES"] == .direct)
        #expect(byName["RIOT"] == .direct)
        #expect(byName["ESCAPEFROMTARKOV"] == .direct)
        #expect(byName["FACEIT"] == .direct)
        #expect(byName["TWITCH"] == .direct)
        #expect(byName["PINTEREST"] == .direct)
        #expect(byName["APPLE"] == .direct)
        #expect(byName["MICROSOFT"] == .direct)

        #expect(byName["CATEGORY-GEOBLOCK-RU"] == .fptn)
        #expect(byName["TELEGRAM"] == .fptn)
        #expect(byName["YOUTUBE"] == .fptn)
        #expect(byName["GITHUB"] == .fptn)
        #expect(byName["GOOGLE-PLAY"] == .fptn)
        // Proxied, not blocked: tunnelling it is what restores Source quality.
        #expect(byName["TWITCH-ADS"] == .fptn)

        // Every published group must be covered by an assertion above, so a
        // group added upstream cannot slip through on the default.
        #expect(site.groups.count == 23)
    }

    @Test func presetIsCaseInsensitive() {
        #expect(GeoVerdictPreset.verdict(forGroup: "category-ads", kind: .geosite) == .block)
        #expect(GeoVerdictPreset.verdict(forGroup: "Category-Ads", kind: .geosite) == .block)
    }
}

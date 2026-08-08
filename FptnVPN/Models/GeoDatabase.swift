/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

// MARK: - Verdict

/// What a routing rule would do with a flow. Mirrors the native `RouteAction`
/// (`direct` / `fptn_l4` / `reject` / `drop`), collapsed to the three outcomes
/// worth showing a person — reject and drop differ only in *how* a blocked flow
/// fails, which is a detail of the engine, not of the rule.
///
/// Nothing here reaches the tunnel yet. The verdicts are a stated reading of
/// what each geo group is *for*, so the database can be inspected before it is
/// trusted with traffic.
enum GeoVerdict: String, Sendable, CaseIterable {
    case direct
    case fptn
    case block

    var displayName: String {
        switch self {
        case .direct: "Direct"
        case .fptn:   "FPTN"
        case .block:  "Block"
        }
    }

    /// Long form for the legend, phrased from the traffic's point of view.
    var explanation: String {
        switch self {
        case .direct: "Leaves from this device, bypassing the server."
        case .fptn:   "Goes through the FPTN server."
        case .block:  "Never leaves the device."
        }
    }
}

// MARK: - Addresses

/// An IPv4 or IPv6 address held as a fixed 128-bit value, so both families
/// compare and mask with the same code. IPv4 occupies the low 32 bits.
struct GeoAddress: Hashable, Sendable {
    var high: UInt64
    var low: UInt64
    var isIPv6: Bool

    var bitWidth: UInt8 { isIPv6 ? 128 : 32 }

    init(high: UInt64, low: UInt64, isIPv6: Bool) {
        self.high = high
        self.low = low
        self.isIPv6 = isIPv6
    }

    /// Builds an address from the raw bytes carried in a `CIDR.ip` field:
    /// 4 bytes for IPv4, 16 for IPv6. Any other length is not an address.
    init?(rawBytes: [UInt8]) {
        switch rawBytes.count {
        case 4:
            var value: UInt32 = 0
            for byte in rawBytes { value = (value << 8) | UInt32(byte) }
            self.init(high: 0, low: UInt64(value), isIPv6: false)
        case 16:
            var high: UInt64 = 0
            var low: UInt64 = 0
            for byte in rawBytes[0..<8] { high = (high << 8) | UInt64(byte) }
            for byte in rawBytes[8..<16] { low = (low << 8) | UInt64(byte) }
            self.init(high: high, low: low, isIPv6: true)
        default:
            return nil
        }
    }

    /// Parses a textual address. Uses `inet_pton` rather than hand-rolled
    /// splitting so that IPv6 shorthand, embedded IPv4 and rejection of
    /// malformed input all behave exactly as the system resolver does.
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var v4 = in_addr()
        if trimmed.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.init(high: 0, low: UInt64(UInt32(bigEndian: v4.s_addr)), isIPv6: false)
            return
        }

        var v6 = in6_addr()
        if trimmed.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            self.init(rawBytes: bytes)
            return
        }
        return nil
    }

    var displayText: String {
        if isIPv6 {
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { buffer in
                for index in 0..<8 { buffer[index] = UInt8((high >> (56 - 8 * UInt64(index))) & 0xFF) }
                for index in 0..<8 { buffer[8 + index] = UInt8((low >> (56 - 8 * UInt64(index))) & 0xFF) }
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "?" }
            return String(cString: text)
        }
        let value = UInt32(truncatingIfNeeded: low)
        return "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Clears every bit below the prefix. Rules in the wild are not always
    /// stored already masked, and an unmasked base would make containment
    /// tests wrong rather than merely untidy.
    func masked(prefix: UInt8) -> GeoAddress {
        let width = bitWidth
        guard prefix < width else { return self }
        if isIPv6 {
            if prefix == 0 { return GeoAddress(high: 0, low: 0, isIPv6: true) }
            if prefix <= 64 {
                let keep = UInt64.max << (64 - UInt64(prefix))
                return GeoAddress(high: high & keep, low: 0, isIPv6: true)
            }
            let keep = UInt64.max << (128 - UInt64(prefix))
            return GeoAddress(high: high, low: low & keep, isIPv6: true)
        }
        if prefix == 0 { return GeoAddress(high: 0, low: 0, isIPv6: false) }
        let keep = UInt32.max << (32 - UInt32(prefix))
        return GeoAddress(high: 0, low: UInt64(UInt32(truncatingIfNeeded: low) & keep), isIPv6: false)
    }
}

// MARK: - Rules

/// One CIDR from `geoip.dat`.
///
/// Deliberately a flat value type carrying its own group index rather than
/// living inside a per-group array: the screen needs one searchable sequence
/// across every group, and 42k entries should not each own a String.
struct GeoCIDRRule: Identifiable, Sendable {
    let base: GeoAddress
    let prefix: UInt8
    let groupIndex: Int
    let id: Int

    var displayText: String { "\(base.displayText)/\(prefix)" }

    /// Number of addresses the rule claims. A /32 is one host, a /24 is 256.
    var addressCount: Double { exp2(Double(base.bitWidth) - Double(prefix)) }

    /// Bar width for the coverage glyph, 0...1.
    ///
    /// Linear in the *prefix*, not in the address count: address counts span
    /// 2^32, so a proportional bar would render every rule in this file as an
    /// invisible sliver. Prefix length is what a person reading a routing
    /// table actually compares.
    var coverageWeight: Double {
        1.0 - Double(prefix) / Double(base.bitWidth)
    }

    func contains(_ address: GeoAddress) -> Bool {
        guard address.isIPv6 == base.isIPv6 else { return false }
        return address.masked(prefix: prefix) == base
    }
}

/// One domain rule from `geosite.dat`.
struct GeoDomainRule: Identifiable, Sendable {
    /// The four matching modes the format defines. Only `rootDomain` is
    /// supported by the native `StaticDomainPolicy` today — the others are
    /// parsed and shown so the gap is visible rather than silent.
    enum Kind: Int, Sendable {
        case plain = 0
        case regex = 1
        case rootDomain = 2
        case full = 3

        var displayName: String {
            switch self {
            case .plain:      "contains"
            case .regex:      "regex"
            case .rootDomain: "suffix"
            case .full:       "exact"
            }
        }

        /// Whether the native engine can currently honour this rule.
        var isSupportedByEngine: Bool { self == .rootDomain }
    }

    let kind: Kind
    let value: String
    let groupIndex: Int
    let id: Int

    /// Label-aware suffix test, matching the semantics documented on
    /// `StaticDomainPolicy`: `mail.ru` matches `smtp.mail.ru` but never
    /// `notmail.ru`.
    func matches(_ domain: String) -> Bool {
        let candidate = domain.lowercased()
        switch kind {
        case .full:
            return candidate == value
        case .rootDomain:
            if candidate == value { return true }
            return candidate.hasSuffix("." + value)
        case .plain:
            return candidate.contains(value)
        case .regex:
            return candidate.range(of: value, options: .regularExpression) != nil
        }
    }
}

// MARK: - Groups

struct GeoGroup: Identifiable, Sendable {
    let name: String
    let index: Int
    let entryCount: Int
    let verdict: GeoVerdict
    /// `inverse_match` on a geoip group means "everything except these", which
    /// nothing in the current data uses. Carried so that a future file that
    /// does use it cannot be read as its own opposite.
    let isInverse: Bool

    var id: Int { index }
}

// MARK: - Tables

struct GeoIPTable: Sendable {
    let groups: [GeoGroup]
    let rules: [GeoCIDRRule]

    var ruleCount: Int { rules.count }
    var ipv6Count: Int { rules.reduce(into: 0) { $0 += $1.base.isIPv6 ? 1 : 0 } }

    /// Longest-prefix match, the way a routing table resolves an address.
    ///
    /// A linear pass rather than a trie: 42k comparisons is a few hundred
    /// microseconds, it runs once per query typed by a person, and it is
    /// obviously correct in the presence of the heavy overlap this data has
    /// (98% of WHITELIST sits inside a DIRECT range, so "first match wins"
    /// would return whichever group happened to be serialized first).
    func longestPrefixMatch(_ address: GeoAddress) -> GeoCIDRRule? {
        var best: GeoCIDRRule?
        for rule in rules where rule.contains(address) {
            if best == nil || rule.prefix > best!.prefix { best = rule }
        }
        return best
    }
}

struct GeoSiteTable: Sendable {
    let groups: [GeoGroup]
    let rules: [GeoDomainRule]

    var ruleCount: Int { rules.count }

    /// Resolves a domain the way the engine would: an exact rule beats a
    /// suffix rule, and a longer suffix beats a shorter one. `plain` and
    /// `regex` are consulted last because they are the least specific and,
    /// today, unsupported downstream.
    func bestMatch(for domain: String) -> GeoDomainRule? {
        let candidate = domain.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !candidate.isEmpty else { return nil }

        var bestSuffix: GeoDomainRule?
        var fallback: GeoDomainRule?
        for rule in rules {
            guard rule.matches(candidate) else { continue }
            switch rule.kind {
            case .full:
                return rule
            case .rootDomain:
                if bestSuffix == nil || rule.value.count > bestSuffix!.value.count { bestSuffix = rule }
            case .plain, .regex:
                if fallback == nil { fallback = rule }
            }
        }
        return bestSuffix ?? fallback
    }
}

// MARK: - Provenance

/// What was downloaded, and proof of which bytes they were. Recorded per file
/// so a stale half of the pair cannot masquerade as a fresh download.
struct GeoFileProvenance: Codable, Sendable, Equatable {
    let sourceURL: URL
    let fetchedAt: Date
    let byteCount: Int
    /// Full hex SHA-256. Shown truncated; kept whole so it can be compared
    /// against the publisher's.
    let sha256: String

    var shortHash: String { String(sha256.prefix(12)) }
}

// MARK: - Database

struct GeoDatabase: Sendable {
    let ip: GeoIPTable
    let site: GeoSiteTable
    let ipProvenance: GeoFileProvenance
    let siteProvenance: GeoFileProvenance
    /// Wall-clock cost of decoding both files, reported in the UI. The point of
    /// this screen is to show the database really loaded; a number nobody can
    /// argue with serves that better than a checkmark.
    let parseDuration: Duration

    var totalRuleCount: Int { ip.ruleCount + site.ruleCount }

    var newestFetchDate: Date {
        max(ipProvenance.fetchedAt, siteProvenance.fetchedAt)
    }
}

// MARK: - Fixed verdict preset

/// The v1 reading of what each published group is for.
///
/// This is a fixed table on purpose. It is not user-editable and it is not
/// consulted by the tunnel — split routing still runs its own built-in test
/// policy. It exists so the browser can show what each group would *mean*,
/// which is most of the value of being able to read the database at all.
///
/// The names come from roscomvpn's own grouping; the verdicts are ours.
enum GeoVerdictPreset {
    static func verdict(forGroup name: String, kind: GeoDataKind) -> GeoVerdict {
        let key = name.uppercased()
        switch kind {
        case .geoip:
            // Every published geoip group is a "reach this without the server"
            // set: RU-facing ranges, plus RFC1918 which must never be tunnelled.
            return .direct
        case .geosite:
            switch key {
            case "CATEGORY-ADS", "TWITCH-ADS", "WIN-SPY":
                return .block
            case "WHITELIST", "CATEGORY-RU", "PRIVATE":
                return .direct
            default:
                // Everything else is a service that is either blocked from
                // Russia or blocks Russia, so it needs the server.
                return .fptn
            }
        }
    }
}

/// Which of the two published files a group came from.
enum GeoDataKind: String, Sendable, CaseIterable {
    case geoip
    case geosite

    var displayName: String {
        switch self {
        case .geoip:   "IP ranges"
        case .geosite: "Domains"
        }
    }

    var fileName: String {
        switch self {
        case .geoip:   "geoip.dat"
        case .geosite: "geosite.dat"
        }
    }
}

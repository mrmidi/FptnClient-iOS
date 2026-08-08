/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation

// MARK: - Errors

/// Every failure names the byte offset it happened at. These files are
/// downloaded from a third party, so "the database is corrupt" is a report a
/// person may actually have to act on.
enum GeoDatParseError: Error, LocalizedError, Equatable {
    case empty
    case gzipped
    case truncated(offset: Int)
    case illegalFieldNumber(offset: Int)
    case unsupportedWireType(Int, offset: Int)
    case unexpectedWireType(field: Int, got: Int, expected: Int)
    case invalidAddressLength(Int)
    case invalidPrefix(UInt8, isIPv6: Bool)
    case unnamedGroup(index: Int)
    case noGroups

    var errorDescription: String? {
        switch self {
        case .empty:
            "The file is empty."
        case .gzipped:
            "The file is gzip-compressed. This build reads only uncompressed .dat files."
        case .truncated(let offset):
            "The file ends mid-record at byte \(offset)."
        case .illegalFieldNumber(let offset):
            "Invalid record marker at byte \(offset)."
        case .unsupportedWireType(let wire, let offset):
            "Unsupported record type \(wire) at byte \(offset)."
        case .unexpectedWireType(let field, let got, let expected):
            "Field \(field) is encoded as type \(got), expected \(expected)."
        case .invalidAddressLength(let count):
            "An address is \(count) bytes long; expected 4 or 16."
        case .invalidPrefix(let prefix, let isIPv6):
            "Prefix /\(prefix) is out of range for IPv\(isIPv6 ? "6" : "4")."
        case .unnamedGroup(let index):
            "Group \(index) has no name."
        case .noGroups:
            "The file contains no groups."
        }
    }
}

// MARK: - Wire reader

/// The slice of protobuf needed to read the V2Ray geo formats: varints,
/// length-delimited submessages, and enough of the rest to *skip* fields we do
/// not model. Unknown fields are skipped rather than rejected — the publisher
/// is free to add fields, and a reader that refuses to is a reader that breaks
/// on the next release.
private struct GeoWireReader {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int

    init(_ bytes: [UInt8], range: Range<Int>? = nil) {
        self.bytes = bytes
        let effective = range ?? bytes.startIndex..<bytes.endIndex
        self.position = effective.lowerBound
        self.end = effective.upperBound
    }

    var isAtEnd: Bool { position >= end }
    var offset: Int { position }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let start = position
        while position < end {
            let byte = bytes[position]
            position += 1
            // Bits beyond 64 would silently wrap; a varint that long is
            // malformed rather than merely large.
            if shift >= 64 { throw GeoDatParseError.illegalFieldNumber(offset: start) }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw GeoDatParseError.truncated(offset: start)
    }

    /// Returns the next field's number and wire type, or nil at the end.
    mutating func nextField() throws -> (number: Int, wireType: Int)? {
        guard !isAtEnd else { return nil }
        let start = position
        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = Int(key & 0x07)
        guard number != 0 else { throw GeoDatParseError.illegalFieldNumber(offset: start) }
        return (number, wireType)
    }

    /// Range of a length-delimited field's payload, without copying it.
    mutating func readLengthDelimitedRange() throws -> Range<Int> {
        let start = position
        let raw = try readVarint()
        // A hostile or corrupt file can encode a length larger than Int, and
        // both the conversion and `position + length` would trap rather than
        // throw. Compare against the remaining bytes instead.
        guard let length = Int(exactly: raw), length <= end - position else {
            throw GeoDatParseError.truncated(offset: start)
        }
        let range = position..<(position + length)
        position += length
        return range
    }

    mutating func readBytes() throws -> [UInt8] {
        Array(bytes[try readLengthDelimitedRange()])
    }

    /// Decodes as UTF-8, falling back to a lossy read. A group name that is not
    /// valid UTF-8 is a bad file, but losing the whole database over one byte
    /// helps nobody.
    mutating func readString() throws -> String {
        let raw = try readBytes()
        return String(decoding: raw, as: UTF8.self)
    }

    mutating func skip(wireType: Int) throws {
        let start = position
        switch wireType {
        case 0: _ = try readVarint()
        case 1: try advance(by: 8, from: start)
        case 2: _ = try readLengthDelimitedRange()
        case 5: try advance(by: 4, from: start)
        default: throw GeoDatParseError.unsupportedWireType(wireType, offset: start)
        }
    }

    private mutating func advance(by count: Int, from start: Int) throws {
        guard position + count <= end else { throw GeoDatParseError.truncated(offset: start) }
        position += count
    }

    func subReader(_ range: Range<Int>) -> GeoWireReader {
        GeoWireReader(bytes, range: range)
    }

    static func expect(_ got: Int, _ expected: Int, field: Int) throws {
        guard got == expected else {
            throw GeoDatParseError.unexpectedWireType(field: field, got: got, expected: expected)
        }
    }
}

// MARK: - Parser

/// Decodes the standard V2Ray/Xray `geosite.dat` and `geoip.dat` containers.
///
/// Schema (only the fields that carry meaning here):
///
///     GeoSiteList { repeated GeoSite entry = 1 }
///     GeoSite     { string country_code = 1; repeated Domain domain = 2;
///                   bytes resource_hash = 3; string code = 4 }
///     Domain      { Type type = 1; string value = 2; repeated Attribute attribute = 3 }
///
///     GeoIPList   { repeated GeoIP entry = 1 }
///     GeoIP       { string country_code = 1; repeated CIDR cidr = 2;
///                   bool inverse_match = 3; bytes resource_hash = 4; string code = 5 }
///     CIDR        { bytes ip = 1; uint32 prefix = 2 }
///
/// Nothing is deduplicated or collapsed. Groups overlap heavily by design —
/// 98% of the published WHITELIST ranges sit inside a DIRECT range — and
/// merging them here would bake in a precedence decision that belongs to
/// whoever assigns verdicts, not to the reader of the file.
enum GeoDatParser {

    static func parseGeoIP(_ data: Data) throws -> GeoIPTable {
        let bytes = try validatedBytes(data)
        var groups: [GeoGroup] = []
        var rules: [GeoCIDRRule] = []
        var reader = GeoWireReader(bytes)

        while let field = try reader.nextField() {
            guard field.number == 1 else {
                try reader.skip(wireType: field.wireType)
                continue
            }
            try GeoWireReader.expect(field.wireType, 2, field: 1)
            let range = try reader.readLengthDelimitedRange()
            let groupIndex = groups.count
            let group = try parseGeoIPGroup(
                reader.subReader(range),
                index: groupIndex,
                rules: &rules
            )
            groups.append(group)
        }

        guard !groups.isEmpty else { throw GeoDatParseError.noGroups }
        return GeoIPTable(groups: groups, rules: rules)
    }

    static func parseGeoSite(_ data: Data) throws -> GeoSiteTable {
        let bytes = try validatedBytes(data)
        var groups: [GeoGroup] = []
        var rules: [GeoDomainRule] = []
        var reader = GeoWireReader(bytes)

        while let field = try reader.nextField() {
            guard field.number == 1 else {
                try reader.skip(wireType: field.wireType)
                continue
            }
            try GeoWireReader.expect(field.wireType, 2, field: 1)
            let range = try reader.readLengthDelimitedRange()
            let groupIndex = groups.count
            let group = try parseGeoSiteGroup(
                reader.subReader(range),
                index: groupIndex,
                rules: &rules
            )
            groups.append(group)
        }

        guard !groups.isEmpty else { throw GeoDatParseError.noGroups }
        return GeoSiteTable(groups: groups, rules: rules)
    }

    // MARK: Group decoding

    private static func parseGeoIPGroup(
        _ reader: GeoWireReader,
        index: Int,
        rules: inout [GeoCIDRRule]
    ) throws -> GeoGroup {
        var reader = reader
        var countryCode = ""
        var code = ""
        var isInverse = false
        var count = 0

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                try GeoWireReader.expect(field.wireType, 2, field: 1)
                countryCode = try reader.readString()
            case 2:
                try GeoWireReader.expect(field.wireType, 2, field: 2)
                let range = try reader.readLengthDelimitedRange()
                let (base, prefix) = try parseCIDR(reader.subReader(range))
                rules.append(GeoCIDRRule(
                    base: base.masked(prefix: prefix),
                    prefix: prefix,
                    groupIndex: index,
                    id: rules.count
                ))
                count += 1
            case 3:
                try GeoWireReader.expect(field.wireType, 0, field: 3)
                isInverse = try reader.readVarint() != 0
            case 5:
                try GeoWireReader.expect(field.wireType, 2, field: 5)
                code = try reader.readString()
            default:
                try reader.skip(wireType: field.wireType)
            }
        }

        let name = code.isEmpty ? countryCode : code
        guard !name.isEmpty else { throw GeoDatParseError.unnamedGroup(index: index) }
        return GeoGroup(
            name: name.uppercased(),
            index: index,
            entryCount: count,
            verdict: GeoVerdictPreset.verdict(forGroup: name, kind: .geoip),
            isInverse: isInverse
        )
    }

    private static func parseGeoSiteGroup(
        _ reader: GeoWireReader,
        index: Int,
        rules: inout [GeoDomainRule]
    ) throws -> GeoGroup {
        var reader = reader
        var countryCode = ""
        var code = ""
        var count = 0

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                try GeoWireReader.expect(field.wireType, 2, field: 1)
                countryCode = try reader.readString()
            case 2:
                try GeoWireReader.expect(field.wireType, 2, field: 2)
                let range = try reader.readLengthDelimitedRange()
                if let rule = try parseDomain(
                    reader.subReader(range),
                    groupIndex: index,
                    id: rules.count
                ) {
                    rules.append(rule)
                    count += 1
                }
            case 4:
                try GeoWireReader.expect(field.wireType, 2, field: 4)
                code = try reader.readString()
            default:
                try reader.skip(wireType: field.wireType)
            }
        }

        let name = code.isEmpty ? countryCode : code
        guard !name.isEmpty else { throw GeoDatParseError.unnamedGroup(index: index) }
        return GeoGroup(
            name: name.uppercased(),
            index: index,
            entryCount: count,
            verdict: GeoVerdictPreset.verdict(forGroup: name, kind: .geosite),
            isInverse: false
        )
    }

    // MARK: Leaf decoding

    private static func parseCIDR(_ reader: GeoWireReader) throws -> (GeoAddress, UInt8) {
        var reader = reader
        var raw: [UInt8] = []
        var prefix: UInt64 = 0

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                try GeoWireReader.expect(field.wireType, 2, field: 1)
                raw = try reader.readBytes()
            case 2:
                try GeoWireReader.expect(field.wireType, 0, field: 2)
                prefix = try reader.readVarint()
            default:
                try reader.skip(wireType: field.wireType)
            }
        }

        guard let address = GeoAddress(rawBytes: raw) else {
            throw GeoDatParseError.invalidAddressLength(raw.count)
        }
        let width = address.bitWidth
        guard prefix <= UInt64(width) else {
            throw GeoDatParseError.invalidPrefix(UInt8(min(prefix, 255)), isIPv6: address.isIPv6)
        }
        return (address, UInt8(prefix))
    }

    /// Returns nil for a rule with an empty value, which carries no meaning and
    /// would otherwise match everything under `plain`.
    private static func parseDomain(
        _ reader: GeoWireReader,
        groupIndex: Int,
        id: Int
    ) throws -> GeoDomainRule? {
        var reader = reader
        var kindValue: UInt64 = 0
        var value = ""

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                try GeoWireReader.expect(field.wireType, 0, field: 1)
                kindValue = try reader.readVarint()
            case 2:
                try GeoWireReader.expect(field.wireType, 2, field: 2)
                value = try reader.readString()
            default:
                // Field 3 is the attribute list (`@cn`, `@ads`), unused here.
                try reader.skip(wireType: field.wireType)
            }
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        // An unknown type is read as `plain`, which is what the format's own
        // default is for an absent field.
        let kind = GeoDomainRule.Kind(rawValue: Int(kindValue)) ?? .plain
        return GeoDomainRule(kind: kind, value: trimmed, groupIndex: groupIndex, id: id)
    }

    // MARK: Input checks

    private static func validatedBytes(_ data: Data) throws -> [UInt8] {
        guard !data.isEmpty else { throw GeoDatParseError.empty }
        // These files are published uncompressed. Recognising the gzip magic
        // gives a precise error instead of a stream of nonsense field numbers.
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            throw GeoDatParseError.gzipped
        }
        return [UInt8](data)
    }
}

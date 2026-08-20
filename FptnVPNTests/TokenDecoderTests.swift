/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Compression
import Foundation
import Testing
@testable import FptnVPN

/// `TokenDecoder` is the gate every user passes through, and it is now shared by
/// login and the in-place refresh in Settings. The sanitisation is the part that
/// makes real tokens work — chat clients wrap them, users copy the backticks —
/// so it is pinned here rather than left to trial and error in the field.
struct TokenDecoderTests {

    // MARK: - Helpers

    private func makeTokenJSON(serverCount: Int = 2) -> Data {
        let servers = (0..<serverCount).map { i in
            """
            {"name":"srv\(i)","host":"\(i).example.com","port":443,"md5_fingerprint":"fp\(i)"}
            """
        }.joined(separator: ",")
        let json = """
        {"version":1,"service_name":"FPTN","username":"user","password":"pass","servers":[\(servers)]}
        """
        return Data(json.utf8)
    }

    private func plainToken(serverCount: Int = 2) -> String {
        "fptn:" + makeTokenJSON(serverCount: serverCount).base64EncodedString()
    }

    private func brotliCompress(_ data: Data) -> Data {
        let capacity = max(data.count * 2, 4096)
        var out = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_encode_buffer(
                &out, capacity,
                base.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_BROTLI
            )
        }
        return Data(out[..<written])
    }

    // MARK: - Happy paths

    @Test func decodesPlainBase64Token() throws {
        let token = try TokenDecoder.decode(plainToken(serverCount: 3))
        #expect(token.username == "user")
        #expect(token.password == "pass")
        #expect(token.servers.count == 3)
    }

    @Test func decodesBrotliToken() throws {
        let compressed = brotliCompress(makeTokenJSON())
        let raw = "fptnb:" + compressed.base64EncodedString()
        let token = try TokenDecoder.decode(raw)
        #expect(token.servers.count == 2)
    }

    @Test(arguments: ["fptn:", "fptn://"])
    func acceptsBothPlainPrefixForms(prefix: String) throws {
        let raw = prefix + makeTokenJSON().base64EncodedString()
        #expect(try TokenDecoder.decode(raw).servers.count == 2)
    }

    /// `fptnb:` must be stripped before `fptn:`, or the `b` is left behind and
    /// corrupts the payload.
    @Test func stripsBrotliPrefixBeforePlainPrefix() throws {
        let compressed = brotliCompress(makeTokenJSON())
        for prefix in ["fptnb:", "fptnb://"] {
            let token = try TokenDecoder.decode(prefix + compressed.base64EncodedString())
            #expect(token.servers.count == 2, "failed for \(prefix)")
        }
    }

    // MARK: - Sanitisation

    @Test func toleratesWhitespaceNewlinesAndBackticks() throws {
        let base = makeTokenJSON().base64EncodedString()
        let mangled = "`fptn:" + base.prefix(10) + "\n  " + base.dropFirst(10) + "`\n"
        let token = try TokenDecoder.decode(String(mangled))
        #expect(token.servers.count == 2)
    }

    @Test func normalizesURLSafeBase64() throws {
        // Force '+' and '/' into the payload, then present the URL-safe form the
        // way a link-shortener or a bot might.
        var json = makeTokenJSON()
        json.append(contentsOf: Array("////++++".utf8))
        let standard = Data(makeTokenJSON()).base64EncodedString()
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-")
                              .replacingOccurrences(of: "/", with: "_")
        let token = try TokenDecoder.decode("fptn:" + urlSafe)
        #expect(token.servers.count == 2)
    }

    @Test func restoresStrippedBase64Padding() throws {
        let padded = makeTokenJSON().base64EncodedString()
        let unpadded = padded.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = try TokenDecoder.decode("fptn:" + unpadded)
        #expect(token.servers.count == 2)
    }

    // MARK: - Failures

    @Test func emptyInputReportsEmpty() {
        #expect(throws: TokenParseError.empty) { try TokenDecoder.decode("") }
        #expect(throws: TokenParseError.empty) { try TokenDecoder.decode("   \n ") }
    }

    @Test func missingPrefixIsRejectedAsNotAToken() {
        let bare = makeTokenJSON().base64EncodedString()
        #expect(throws: TokenParseError.notAToken) { try TokenDecoder.decode(bare) }
        #expect(throws: TokenParseError.notAToken) { try TokenDecoder.decode("https://example.com") }
    }

    @Test func prefixWithNoPayloadReportsEmpty() {
        #expect(throws: TokenParseError.empty) { try TokenDecoder.decode("fptn:") }
    }

    @Test func undecodableBase64ReportsTruncation() {
        #expect(throws: TokenParseError.invalidBase64) {
            try TokenDecoder.decode("fptn:!!!not base64 at all!!!")
        }
    }

    /// A token that parses but carries no servers is useless; failing here beats
    /// a connect attempt that finds nothing to race.
    @Test func tokenWithoutServersIsRejected() {
        let raw = "fptn:" + Data(#"{"version":1,"service_name":"F","username":"u","password":"p","servers":[]}"#.utf8).base64EncodedString()
        #expect(throws: TokenParseError.noServers) { try TokenDecoder.decode(raw) }
    }

    @Test func nonTokenJSONIsRejected() {
        let raw = "fptn:" + Data(#"{"hello":"world"}"#.utf8).base64EncodedString()
        #expect(throws: (any Error).self) { try TokenDecoder.decode(raw) }
    }

    // MARK: - looksLikeToken

    @Test func looksLikeTokenGatesOnPrefixAndLength() {
        #expect(TokenDecoder.looksLikeToken(plainToken()))
        #expect(!TokenDecoder.looksLikeToken(""))
        #expect(!TokenDecoder.looksLikeToken("just some text"))
        // Right prefix, far too short to be real.
        #expect(!TokenDecoder.looksLikeToken("fptn:abc"))
    }

    /// It is a cheap shape check, so it must never throw regardless of input.
    @Test func looksLikeTokenNeverThrowsOnJunk() {
        for junk in ["", "fptnb:", "fptn://", "\u{0}\u{1}", String(repeating: "x", count: 10_000)] {
            _ = TokenDecoder.looksLikeToken(junk)
        }
    }
}

// Ported from desktop/app/test/unit/parse-pac-string-test.ts

import GitKit
import Testing
import TestSupport

@Suite("parsePACString")
struct ParsePACStringTests {
    @Test("parses PAC strings into proxy URLs", arguments: [
        NamedCase("returns no url for DIRECT", (pac: "DIRECT", expected: nil)),
        NamedCase("parses Chromium PAC strings", (
            pac: "PROXY a:1;HTTP b:2;HTTPS c:3;SOCKS d:4;SOCKS4 e:5;SOCKS5 f:5;DIRECT",
            expected: ["http://a:1", "http://b:2", "https://c:3", "socks4://d:4", "socks4://e:5", "socks5://f:5"]
        )),
        // not strictly necessary as Chromium doesn't add space inbetween
        NamedCase("parses PAC strings with white space between specs", (
            pac: "PROXY a:1; HTTP b:2 ;\tHTTPS c:3\t;\tSOCKS d:4 ; SOCKS4 e:5  ;  SOCKS5 f:5  ; DIRECT",
            expected: ["http://a:1", "http://b:2", "https://c:3", "socks4://d:4", "socks4://e:5", "socks5://f:5"]
        )),
        NamedCase("skips protocols cURL doesn't understand", (pac: "QUIC qhost:1;PROXY phost:2;DIRECT", expected: ["http://phost:2"])),
        NamedCase("skips invalid specs", (pac: "PROXY;HTTPS;DIRECT", expected: nil)),
    ] as [NamedCase<(pac: String, expected: [String]?)>])
    func parses(_ testCase: NamedCase<(pac: String, expected: [String]?)>) {
        #expect(parsePACString(testCase.value.pac) == testCase.value.expected)
    }

    // MARK: - Espalier

    @Test("matches keywords case-insensitively, in ASCII only")
    func caseInsensitive() {
        #expect(parsePACString("proxy a:1; Socks5 b:2") == ["http://a:1", "socks5://b:2"])
        #expect(parsePACString("direct; PROXY a:1") == nil)
        #expect(parsePACString("Directly PROXY a:1") == nil)
        // U+0131 (dotless i) uppercases to I, but JavaScript's /i never
        // matches a non-ASCII character to an ASCII one.
        #expect(parsePACString("D\u{131}RECT; PROXY a:1") == ["http://a:1"])
    }

    @Test("keeps only the first two words of a spec")
    func firstTwoWords() {
        #expect(parsePACString("PROXY a:1 extra") == ["http://a:1"])
        #expect(parsePACString("  PROXY a:1  ") == ["http://a:1"])
        #expect(parsePACString(";;PROXY a:1") == ["http://a:1"])
    }
}

// The proxy exceptions list and the implicit rules, read and matched as
// Chromium does: cases from Chromium's proxy_host_matching_rules_unittest.cc
// (named as there), and the entries where CFNetwork reads the list
// differently.

@testable import GitKit
import Testing
import TestSupport

/// Whether `url` connects without the proxy under these exceptions.
private func bypasses(_ entries: [String], _ url: String, excludeSimpleHostnames: Bool = false) throws -> Bool {
    var rules = ProxyBypassRules()
    for entry in entries {
        rules.add(entry)
    }
    if excludeSimpleHostnames {
        rules.prependSimpleHostnames()
    }
    return rules.matches(try #require(ProxyTarget(url), "\(url)"))
}

/// Localhost and loopback names (`ExpectMatchLocalhost`).
private let localhostHosts = [
    "localhost", "localhost.", "foo.localhost", "127.0.0.1", "127.100.0.2", "[::1]",
    "[::0:FFFF:127.0.0.1]", "[::fFfF:127.100.0.0]", "[0::ffff:7f00:1]",
]

/// Link-local addresses (`ExpectMatchesLinkLocal`).
private let linkLocalHosts = ["169.254.3.2", "169.254.100.1", "[FE80::8]", "[fe91::1]", "[::ffff:169.254.3.2]"]

/// Other hosts (`ExpectMatchesMisc`).
private let otherHosts = [
    "192.168.0.1", "170.254.0.0", "128.0.0.1", "[::2]", "[FD80::1]", "foo", "www.example3.com",
    "[::ffff:128.0.0.1]", "[::ffff:126.100.0.0]", "[::ffff:0:127.0.0.1]", "[::127.0.0.1]", "loopback", "loopback.",
]

/// Whether each host, under http, https, and ftp, matches as expected
/// (`ExpectRulesMatch`), except the inverted ones.
private func expect(_ entries: [String], hosts: [String], match: Bool, except inverted: Set<String> = [], sourceLocation: SourceLocation = #_sourceLocation) throws {
    for scheme in ["http://", "https://", "ftp://"] {
        for host in hosts {
            let expected = inverted.contains(host) ? !match : match
            #expect(try bypasses(entries, scheme + host) == expected, "\(scheme)\(host)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Proxy bypass rules")
struct ProxyBypassRulesTests {
    @Test("ParseAndMatchBasicHost")
    func basicHost() throws {
        let rules = ["wWw.gOogle.com"]
        #expect(ProxyBypassRules.rule(rules[0]) == .hostnamePattern(scheme: nil, pattern: "www.google.com", port: nil))
        #expect(try bypasses(rules, "http://www.google.com"))
        #expect(try bypasses(rules, "ftp://www.google.com:99"))
        #expect(try bypasses(rules, "https://www.google.com:81"))
        #expect(try !bypasses(rules, "http://foo.www.google.com"))
        #expect(try !bypasses(rules, "http://xxx.google.com"))
        #expect(try !bypasses(rules, "http://google.com"))
        #expect(try !bypasses(rules, "http://www.google.com.baz.org"))
    }

    @Test("ParseAndMatchBasicDomain")
    func basicDomain() throws {
        let rules = [".gOOgle.com"]
        #expect(ProxyBypassRules.rule(rules[0]) == .hostnamePattern(scheme: nil, pattern: "*.google.com", port: nil))
        #expect(try bypasses(rules, "http://www.google.com"))
        #expect(try bypasses(rules, "ftp://www.google.com:99"))
        #expect(try bypasses(rules, "https://a.google.com:81"))
        #expect(try bypasses(rules, "http://foo.google.com/x/y?q"))
        #expect(try bypasses(rules, "http://foo:bar@baz.google.com#x"))
        #expect(try !bypasses(rules, "http://google.com"))
        #expect(try !bypasses(rules, "http://foo.google.com.baz.org"))
    }

    @Test("ParseAndMatchBasicDomainWithPort")
    func basicDomainWithPort() throws {
        let rules = ["*.GOOGLE.com:80"]
        #expect(try bypasses(rules, "http://www.google.com"))
        #expect(try bypasses(rules, "ftp://www.google.com:80"))
        #expect(try bypasses(rules, "https://a.google.com:80?x"))
        #expect(try !bypasses(rules, "http://google.com"))
        #expect(try !bypasses(rules, "http://foo.google.com.baz.org"))
        #expect(try !bypasses(rules, "http://www.google.com:90"))
        #expect(try !bypasses(rules, "https://www.google.com"))
    }

    @Test("MatchAll")
    func matchAll() throws {
        #expect(try bypasses(["*"], "http://www.google.com"))
        #expect(try bypasses(["*"], "ftp://www.foobar.com:99"))
        #expect(try bypasses(["*"], "https://a.google.com:80?x"))
    }

    @Test("WildcardAtStart")
    func wildcardAtStart() throws {
        let rules = ["*.org:443"]
        #expect(try bypasses(rules, "http://www.google.org:443"))
        #expect(try bypasses(rules, "https://www.google.org"))
        #expect(try !bypasses(rules, "http://www.google.org"))
        #expect(try !bypasses(rules, "https://www.google.com"))
        #expect(try !bypasses(rules, "https://www.google.org.com"))
    }

    @Test("rejects entries Chromium can't read", arguments: [
        // ParseInvalidPort
        "*.com:+443", "*.com:-443",
        // BadInputs
        "://", "  ", "http://",
        // ParseBracketedIPv6Range
        "[a:b:c:d::]/48",
        "10.0.0.0/33", "example.com:65536",
    ])
    func badInputs(_ entry: String) {
        #expect(ProxyBypassRules.rule(entry) == nil)
    }

    @Test("IPV4Address and IPV4AddressWithPort")
    func ipv4Address() throws {
        #expect(try bypasses(["192.168.1.1"], "http://192.168.1.1"))
        #expect(try bypasses(["192.168.1.1"], "https://192.168.1.1:90"))
        #expect(try !bypasses(["192.168.1.1"], "http://www.google.com"))
        #expect(try !bypasses(["192.168.1.1"], "http://sup.192.168.1.1"))

        #expect(try bypasses(["192.168.1.1:33"], "http://192.168.1.1:33"))
        #expect(try !bypasses(["192.168.1.1:33"], "http://192.168.1.1"))
        #expect(try !bypasses(["192.168.1.1:33"], "http://sup.192.168.1.1:33"))
    }

    @Test("IPV6Address and IPV6AddressWithPort")
    func ipv6Address() throws {
        #expect(try bypasses(["[3ffe:2a00:100:7031:0:0::1]"], "http://[3ffe:2a00:100:7031::1]"))
        #expect(try bypasses(["[3ffe:2a00:100:7031:0:0::1]"], "http://[3ffe:2a00:100:7031::1]:33"))
        #expect(try !bypasses(["[3ffe:2a00:100:7031:0:0::1]"], "http://www.google.com"))

        #expect(try bypasses(["[3ffe:2a00:100:7031::1]:33"], "http://[3ffe:2a00:100:7031::1]:33"))
        #expect(try !bypasses(["[3ffe:2a00:100:7031::1]:33"], "http://[3ffe:2a00:100:7031::1]"))
    }

    @Test("HTTPOnly and HTTPOnlyWithWildcard")
    func schemes() throws {
        #expect(try bypasses(["http://www.google.com"], "http://www.google.com/foo"))
        #expect(try bypasses(["http://www.google.com"], "http://www.google.com:99"))
        #expect(try !bypasses(["http://www.google.com"], "https://www.google.com"))
        #expect(try !bypasses(["http://www.google.com"], "ftp://www.google.com"))
        #expect(try !bypasses(["http://www.google.com"], "http://foo.www.google.com"))

        #expect(try bypasses(["http://*www.google.com"], "http://foo.www.google.com"))
        #expect(try !bypasses(["http://*www.google.com"], "http://www.google.com.org"))
        #expect(try !bypasses(["http://*www.google.com"], "https://www.google.com"))
    }

    @Test("DoesNotUseSuffixMatching and MultipleRules")
    func multipleRules() throws {
        let suffixes = ["foo1.com", ".foo2.com", "192.168.1.1", "*foobar.com:80", "*.foo", "http://baz", "<local>"]
        #expect(try bypasses(suffixes, "http://foo1.com"))
        #expect(try !bypasses(suffixes, "http://aaafoo1.com"))
        #expect(try !bypasses(suffixes, "http://aaafoo1.com.net"))

        let rules = [".google.com ", " .foobar.com:30"]
        #expect(try bypasses(rules, "http://baz.google.com:40"))
        #expect(try !bypasses(rules, "http://google.com:40"))
        #expect(try bypasses(rules, "http://bar.foobar.com:30"))
        #expect(try !bypasses(rules, "http://bar.foobar.com"))
        #expect(try !bypasses(rules, "http://bar.foobar.com:33"))
    }

    @Test("MatchSimpleHostnames")
    func simpleHostnames() throws {
        let rules = ["<-loopback>", "<local>"]
        #expect(try bypasses(rules, "http://example/"))
        #expect(try !bypasses(rules, "http://example./"))
        #expect(try !bypasses(rules, "http://example.com/"))
        #expect(try !bypasses(rules, "http://[dead::beef]/"))
        #expect(try !bypasses(rules, "http://192.168.1.1/"))
        try expect(rules, hosts: localhostHosts, match: false, except: ["localhost"])
        try expect(rules, hosts: linkLocalHosts, match: false)
        try expect(rules, hosts: otherHosts, match: false, except: ["foo", "loopback"])
        // "Exclude simple hostnames" is the same rule, first.
        #expect(try bypasses([], "https://intranet/repository.git", excludeSimpleHostnames: true))
        #expect(try !bypasses([], "https://github.com/repository.git", excludeSimpleHostnames: true))
    }

    @Test("ParseAndMatchCIDR_IPv4")
    func cidrIPv4() throws {
        let rules = ["192.168.1.1/16"]
        #expect(try bypasses(rules, "http://192.168.1.1"))
        #expect(try bypasses(rules, "ftp://192.168.4.4"))
        #expect(try bypasses(rules, "https://192.168.0.0:81"))
        #expect(try bypasses(rules, "http://[::ffff:192.168.11.11]"))
        #expect(try !bypasses(rules, "http://foobar.com"))
        #expect(try !bypasses(rules, "http://192.169.1.1"))
        #expect(try !bypasses(rules, "http://xxx.192.168.1.1"))
        #expect(try !bypasses(rules, "http://192.168.1.1.xx"))
    }

    @Test("ParseAndMatchCIDR_IPv6")
    func cidrIPv6() throws {
        #expect(try bypasses(["a:b:c:d::/48"], "http://[A:b:C:9::]"))
        #expect(try !bypasses(["a:b:c:d::/48"], "http://foobar.com"))
        #expect(try !bypasses(["a:b:c:d::/48"], "http://192.169.1.1"))

        #expect(try bypasses(["::ffff:192.168.1.1/112"], "http://[::ffff:192.168.1.3]"))
        #expect(try bypasses(["::ffff:192.168.1.1/112"], "http://192.168.11.11"))
        #expect(try !bypasses(["::ffff:192.168.1.1/112"], "http://10.10.1.1"))

        #expect(try bypasses(["::fffe:192.168.1.1/112"], "http://[::fffe:192.168.1.3]"))
        #expect(try !bypasses(["::fffe:192.168.1.1/112"], "http://[::ffff:192.168.1.3]"))
        #expect(try !bypasses(["::fffe:192.168.1.1/112"], "http://192.168.11.11"))
    }

    @Test("DefaultImplicitRules")
    func implicitRules() throws {
        try expect([], hosts: localhostHosts, match: true)
        try expect([], hosts: linkLocalHosts, match: true)
        try expect([], hosts: otherHosts, match: false)
    }

    @Test("NegativeWinLoopback, RemoveImplicitAndAddLocalhost, AddLocalhostThenRemoveImplicit")
    func subtractingImplicitRules() throws {
        let negative = ["www.example.com", "<-loopback>"]
        try expect(negative, hosts: localhostHosts, match: false)
        try expect(negative, hosts: linkLocalHosts, match: false)
        try expect(negative, hosts: otherHosts, match: false)
        #expect(try bypasses(negative, "http://www.example.com/"))

        let removeThenAdd = ["<-loopback>", "localhost"]
        try expect(removeThenAdd, hosts: localhostHosts, match: false, except: ["localhost"])
        try expect(removeThenAdd, hosts: linkLocalHosts, match: false)

        let addThenRemove = ["localhost", "<-loopback>"]
        try expect(addThenRemove, hosts: localhostHosts, match: false)
    }

    @Test("LoopbackAndLocalCaseInsensitive")
    func caseInsensitiveSpecialRules() {
        #expect(["<Local>", "<-LoopBacK>", "<LoCaL>", "<-LoOpBack>"].map(ProxyBypassRules.rule) == [.simpleHostnames, .subtractImplicit, .simpleHostnames, .subtractImplicit])
    }

    @Test("wildcards: * matches any run, ? zero or one character, and \\ escapes them")
    func wildcards() {
        #expect(ProxyBypassRules.matchPattern("www.google.com", "*.google.com"))
        #expect(!ProxyBypassRules.matchPattern("google.com", "*.google.com"))
        #expect(ProxyBypassRules.matchPattern("notexample.com", "*example.com"))
        #expect(ProxyBypassRules.matchPattern("example.example.org", "example.*"))
        #expect(ProxyBypassRules.matchPattern("anything", "*"))
        #expect(ProxyBypassRules.matchPattern("", "*"))
        #expect(ProxyBypassRules.matchPattern("192.168.1.5", "192.168.1.*"))
        #expect(ProxyBypassRules.matchPattern("host1", "host?"))
        #expect(ProxyBypassRules.matchPattern("host", "host?"))
        #expect(!ProxyBypassRules.matchPattern("host12", "host?"))
        #expect(ProxyBypassRules.matchPattern("a*b", "a\\*b"))
        #expect(!ProxyBypassRules.matchPattern("axb", "a\\*b"))
        #expect(ProxyBypassRules.matchPattern("a.b.c", "a*c"))
        #expect(!ProxyBypassRules.matchPattern("a.b.cd", "a*c"))
    }
}

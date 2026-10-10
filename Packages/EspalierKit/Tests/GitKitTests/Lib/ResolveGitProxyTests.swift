// The resolver, which must produce the proxy URLs desktop gets from
// Chromium for the same macOS settings: CFNetwork's answers and the
// settings read as Chromium reads them, the exceptions and implicit rules,
// proxy auto-configuration and its sources, and the cache of fetched PAC
// files. Nothing here touches the network; PAC files come from local
// sockets.

import CFNetwork
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("resolveGitProxy")
struct ResolveGitProxyTests {
    // MARK: - Mapping CFNetwork's answers

    private static func entry(_ type: CFString, host: String? = nil, port: Any? = nil, socksVersion: CFString? = nil) -> ProxyListEntry? {
        var dictionary: [String: Any] = [kCFProxyTypeKey as String: type as String]
        if let host {
            dictionary[kCFProxyHostNameKey as String] = host
        }
        if let port {
            dictionary[kCFProxyPortNumberKey as String] = port
        }
        if let socksVersion {
            dictionary[kCFStreamPropertySOCKSVersion as String] = socksVersion as String
        }
        return ProxyListEntry(cfNetwork: dictionary)
    }

    private static func proxy(_ scheme: ProxyServer.Scheme, _ host: String, _ port: Int?) throws -> ProxyListEntry {
        .proxy(try #require(ProxyServer(scheme: scheme, host: host, port: port)))
    }

    @Test("reads CFNetwork's proxies as Chromium does")
    func readsDictionaries() throws {
        #expect(Self.entry(kCFProxyTypeNone) == .direct)
        #expect(try Self.entry(kCFProxyTypeHTTP, host: "web.example", port: 8080) == Self.proxy(.http, "web.example", 8080))
        // An HTTPS proxy is an HTTP proxy for https URLs.
        #expect(try Self.entry(kCFProxyTypeHTTPS, host: "secure.example", port: 8443) == Self.proxy(.http, "secure.example", 8443))
        // Chromium can't tell SOCKS versions apart and reads every SOCKS
        // proxy as SOCKS5.
        #expect(try Self.entry(kCFProxyTypeSOCKS, host: "socks.example", port: 1080, socksVersion: kCFStreamSocketSOCKSVersion4) == Self.proxy(.socks5, "socks.example", 1080))
        #expect(try Self.entry(kCFProxyTypeSOCKS, host: "socks.example", port: 1080, socksVersion: kCFStreamSocketSOCKSVersion5) == Self.proxy(.socks5, "socks.example", 1080))
        // A missing port is the scheme's default; a port that isn't a
        // number counts as missing.
        #expect(try Self.entry(kCFProxyTypeHTTPS, host: "secure.example") == Self.proxy(.http, "secure.example", 80))
        #expect(try Self.entry(kCFProxyTypeSOCKS, host: "socks.example", port: "1081") == Self.proxy(.socks5, "socks.example", 1080))
        // Types Chromium leaves out.
        #expect(Self.entry(kCFProxyTypeFTP, host: "ftp.example", port: 21) == nil)
        #expect(Self.entry(kCFProxyTypeAutoConfigurationURL) == nil)
        #expect(Self.entry(kCFProxyTypeHTTP) == nil)
    }

    @Test("writes the PAC strings Chromium reports")
    func pacStrings() throws {
        #expect(pacString(for: []) == "DIRECT")
        #expect(pacString(for: [.direct]) == "DIRECT")
        #expect(try pacString(for: [Self.proxy(.http, "web.example", 8080)]) == "PROXY web.example:8080")
        #expect(try pacString(for: [Self.proxy(.socks5, "socks.example", 1081)]) == "SOCKS5 socks.example:1081")
        #expect(try pacString(for: [Self.proxy(.http, "a", 1), Self.proxy(.socks5, "b", 2), .direct]) == "PROXY a:1;SOCKS5 b:2;DIRECT")
    }

    @Test("canonicalizes the proxy's host, as Chromium does")
    func hosts() throws {
        #expect(try pacString(for: [Self.proxy(.http, "  Secure.EXAMPLE\t", 8443)]) == "PROXY secure.example:8443")
        #expect(try pacString(for: [Self.proxy(.http, "::1", 8443)]) == "PROXY [::1]:8443")
        #expect(try pacString(for: [Self.proxy(.http, "[::1]", 8443)]) == "PROXY [::1]:8443")
        #expect(try pacString(for: [Self.proxy(.http, "[FE80:0:0::1]", 8443)]) == "PROXY [fe80::1]:8443")
        #expect(try pacString(for: [Self.proxy(.http, "127.1", 3128)]) == "PROXY 127.0.0.1:3128")
        #expect(try pacString(for: [Self.proxy(.socks5, "socks.example", nil)]) == "SOCKS5 socks.example:1080")
    }

    @Test("leaves out proxies no URL could name", arguments: [
        // CFNetwork's reading of a PAC file's `PROXY [::1]:8080`.
        ("[", 0), ("", 80), ("a b", 80), ("a;b", 80), ("[::1", 80), ("[nonsense]", 80),
        // Chromium would truncate these to 16 bits: port 0, and 4464.
        ("a", 0), ("a", 70000),
    ] as [(String, Int)])
    func unusableProxies(host: String, port: Int) {
        #expect(ProxyServer(scheme: .http, host: host, port: port) == nil)
    }

    // MARK: - System settings

    private static func resolve(_ url: String, _ settings: [String: any Sendable], options: ProxyAutoConfigurationOptions = testOptions()) async -> String? {
        await resolveGitProxy(url, settings: SystemProxySettings(settings as [String: Any]), options: options)
    }

    /// Options for tests: a timeout, discovery where nothing listens, and a
    /// cache of their own.
    private static func testOptions(timeout: TimeInterval = 5, discoveryURL: URL? = nil, scripts: PACScriptCache = PACScriptCache()) -> ProxyAutoConfigurationOptions {
        var options = ProxyAutoConfigurationOptions()
        options.timeout = timeout
        options.discoveryURL = discoveryURL ?? URL(string: "\(refusingServer)/wpad.dat")!
        options.scripts = scripts
        return options
    }

    private static let secure: [String: any Sendable] = ["HTTPSEnable": 1, "HTTPSProxy": "secure.example", "HTTPSPort": 8443]
    private static let web: [String: any Sendable] = ["HTTPEnable": 1, "HTTPProxy": "web.example", "HTTPPort": 8080]
    private static let socks: [String: any Sendable] = ["SOCKSEnable": 1, "SOCKSProxy": "socks.example", "SOCKSPort": 1081]

    private static func merging(_ settings: [String: any Sendable]...) -> [String: any Sendable] {
        settings.reduce(into: [:]) { $0.merge($1) { $1 } }
    }

    @Test("resolves the proxy the settings give for the URL's scheme", arguments: [
        NamedCase("resolves the web proxy for http URLs only", (
            settings: web, url: "http://github.com/desktop/desktop.git", expected: "http://web.example:8080"
        )),
        NamedCase("resolves the web proxy for http URLs only", (
            settings: web, url: "https://github.com/desktop/desktop.git", expected: nil
        )),
        NamedCase("resolves the secure web proxy as an HTTP proxy, as Chromium does", (
            settings: secure, url: "https://github.com/desktop/desktop.git", expected: "http://secure.example:8443"
        )),
        NamedCase("resolves the SOCKS proxy for a scheme without its own proxy", (
            settings: merging(web, socks), url: "https://github.com/desktop/desktop.git", expected: "socks5://socks.example:1081"
        )),
        NamedCase("prefers the scheme's proxy over the SOCKS proxy", (
            settings: merging(secure, socks), url: "https://github.com/desktop/desktop.git", expected: "http://secure.example:8443"
        )),
        NamedCase("skips a proxy with an unusable host for the SOCKS proxy", (
            settings: merging(["HTTPSEnable": 1, "HTTPSProxy": "", "HTTPSPort": 8443], socks), url: "https://github.com/desktop/desktop.git", expected: "socks5://socks.example:1081"
        )),
        NamedCase("ignores a proxy that isn't enabled with a number", (
            settings: ["HTTPSEnable": "1", "HTTPSProxy": "secure.example", "HTTPSPort": 8443], url: "https://github.com/desktop/desktop.git", expected: nil
        )),
    ] as [NamedCase<(settings: [String: any Sendable], url: String, expected: String?)>])
    func settings(_ testCase: NamedCase<(settings: [String: any Sendable], url: String, expected: String?)>) async {
        let (settings, url, expected) = testCase.value
        #expect(await Self.resolve(url, settings) == expected)
    }

    @Test("reads the settings as Chromium's macOS reader does")
    func configuration() throws {
        let configuration = ProxyConfiguration(SystemProxySettings(Self.merging(Self.web, Self.secure, Self.socks, [
            "FTPEnable": 1, "FTPProxy": "ftp.example", "FTPPort": 2121,
            "ProxyAutoDiscoveryEnable": 1,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://pac.example/proxy.pac",
            "ExceptionsList": ["*.local", 7, "169.254/16"] as [any Sendable],
            "ExcludeSimpleHostnames": 1,
        ]) as [String: Any]))
        #expect(configuration.autoDetect)
        #expect(configuration.pacURL == URL(string: "http://pac.example/proxy.pac"))
        #expect(configuration.httpProxy == ProxyServer(scheme: .http, host: "web.example", port: 8080))
        #expect(configuration.httpsProxy == ProxyServer(scheme: .http, host: "secure.example", port: 8443))
        #expect(configuration.ftpProxy == ProxyServer(scheme: .http, host: "ftp.example", port: 2121))
        #expect(configuration.fallbackProxy == ProxyServer(scheme: .socks5, host: "socks.example", port: 1081))
        // Non-strings in the exceptions list are skipped; simple host names
        // come first.
        #expect(configuration.bypassRules.rules.count == 3)
        #expect(configuration.bypassRules.rules.first == .simpleHostnames)

        // A PAC URL without the switch on isn't read.
        let off = ProxyConfiguration(SystemProxySettings(["ProxyAutoConfigURLString": "http://pac.example/proxy.pac"] as [String: Any]))
        #expect(!off.hasAutomaticSettings)
    }

    @Test("honors the exceptions as Chromium reads them, where CFNetwork reads them differently", arguments: [
        (["github.com"], "https://github.com/desktop/desktop.git", nil),
        (["github.com"], "https://api.github.com/repos", "http://secure.example:8443"),
        // Matched by CFNetwork, not by Chromium, which reads `192.168` as
        // 192.0.0.168.
        (["192.168/16"], "https://192.168.1.5/repository.git", "http://secure.example:8443"),
    ] as [([String], String, String?)])
    func exceptions(_ list: [String], url: String, expected: String?) async {
        #expect(await Self.resolve(url, Self.merging(Self.secure, ["ExceptionsList": list])) == expected)
    }

    @Test("connects directly to localhost, loopback, and link-local addresses", arguments: [
        "https://localhost/repository.git", "https://127.1.2.3/repository.git", "https://169.254.1.2/repository.git",
    ])
    func implicitBypass(_ url: String) async {
        #expect(await Self.resolve(url, Self.merging(Self.web, Self.secure, Self.socks)) == nil)
        // `<-loopback>` proxies them after all.
        #expect(await Self.resolve(url, Self.merging(Self.web, Self.secure, Self.socks, ["ExceptionsList": ["<-loopback>"]])) != nil)
    }

    @Test("honors simple host names")
    func simpleHostnames() async {
        let settings = Self.merging(Self.secure, ["ExcludeSimpleHostnames": 1])
        #expect(await Self.resolve("https://intranet/repository.git", settings) == nil)
        #expect(await Self.resolve("https://intranet./repository.git", settings) == "http://secure.example:8443")
        #expect(await Self.resolve("https://github.com/repository.git", settings) == "http://secure.example:8443")
    }

    @Test("connects directly without proxy settings or a URL it can read")
    func direct() async {
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", [:]) == nil)
        #expect(await Self.resolve("not a url", Self.secure) == nil)
    }

    // MARK: - Proxy auto-configuration

    private static func pacSettings(_ script: String) -> [String: any Sendable] {
        [
            kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
            kCFNetworkProxiesProxyAutoConfigJavaScript as String: script,
        ]
    }

    private static func pacURLSettings(_ url: String) -> [String: any Sendable] {
        [
            kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
            kCFNetworkProxiesProxyAutoConfigURLString as String: url,
        ]
    }

    @Test("runs a PAC script", arguments: [
        NamedCase("runs a PAC script", (
            script: """
                function FindProxyForURL(url, host) {
                  if (shExpMatch(host, "*.internal")) return "DIRECT";
                  return "PROXY corp.example:3128; DIRECT";
                }
                """,
            expectations: [
                (url: "https://github.com/desktop/desktop.git", expected: "http://corp.example:3128"),
                (url: "http://github.com/desktop/desktop.git", expected: "http://corp.example:3128"),
                (url: "https://git.internal/repository.git", expected: nil),
            ]
        )),
        NamedCase("runs a PAC script's SOCKS answer as SOCKS5, as CFNetwork reads it", (
            script: "function FindProxyForURL(url, host) { return 'SOCKS socks.example:1080'; }",
            expectations: [
                (url: "https://github.com/desktop/desktop.git", expected: "socks5://socks.example:1080"),
            ]
        )),
        NamedCase("doesn't run the PAC script for localhost", (
            script: "function FindProxyForURL(url, host) { return 'PROXY corp.example:3128'; }",
            expectations: [
                (url: "https://localhost/repository.git", expected: nil),
                (url: "https://[::1]/repository.git", expected: nil),
            ]
        )),
        // CFNetwork itself leaves out every URL's path and query.
        NamedCase("gives the PAC script the URL without credentials, path, or query", (
            script: """
                function FindProxyForURL(url, host) {
                  if (url == "https://example.com/" && host == "example.com") return "PROXY clean.example:1";
                  if (url == "http://example.com:8080/") return "PROXY kept.example:2";
                  return "PROXY leaked.example:3";
                }
                """,
            expectations: [
                (url: "https://user:secret@Example.COM/path/repository.git?query#fragment", expected: "http://clean.example:1"),
                (url: "http://user:secret@example.com:8080/path/repository.git?query#fragment", expected: "http://kept.example:2"),
            ]
        )),
    ] as [NamedCase<(script: String, expectations: [(url: String, expected: String?)])>])
    func pacScript(_ testCase: NamedCase<(script: String, expectations: [(url: String, expected: String?)])>) async {
        let settings = Self.pacSettings(testCase.value.script)
        for (url, expected) in testCase.value.expectations {
            #expect(await Self.resolve(url, settings) == expected, "\(url)")
        }
    }

    @Test("reports the proxies a PAC script chooses")
    func executesScript() async throws {
        let proxies = try await executeProxyAutoConfiguration(
            .script("function FindProxyForURL(url, host) { return 'PROXY a.example:1; SOCKS b.example:2; DIRECT'; }"),
            for: URL(string: "https://github.com/desktop/desktop.git")!,
            timeout: 5
        )
        #expect(try proxies == [Self.proxy(.http, "a.example", 1), Self.proxy(.socks5, "b.example", 2), .direct])
    }

    @Test("connects directly when the PAC script fails, even with manual proxies")
    func failingScript() async {
        let failing = "function FindProxyForURL(url, host) { throw new Error('boom'); }"
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", Self.pacSettings(failing)) == nil)
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", Self.merging(Self.pacSettings(failing), Self.secure)) == nil)

        await #expect(throws: (any Error).self) {
            try await executeProxyAutoConfiguration(
                .script("not javascript ("),
                for: URL(string: "https://github.com")!,
                timeout: 5
            )
        }
    }

    @Test("uses the manual proxies when no PAC script loads")
    func manualFallback() async throws {
        // A script without FindProxyForURL isn't one.
        let notPAC = Self.pacSettings("var proxy = 'PROXY corp.example:3128';")
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", Self.merging(notPAC, Self.secure)) == "http://secure.example:8443")
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", notPAC) == nil)

        // A PAC file that can't be fetched.
        let unreachable = Self.pacURLSettings("\(refusingServer)/proxy.pac")
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", unreachable) == nil)
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", Self.merging(unreachable, Self.secure)) == "http://secure.example:8443")
        // The manual proxies' exceptions apply then.
        #expect(await Self.resolve("https://localhost/repository.git", Self.merging(unreachable, Self.secure)) == nil)
    }

    @Test("fetches a PAC file, and uses the manual proxies when it fails to load")
    func pacFile() async throws {
        let script = "function FindProxyForURL(url, host) { return 'PROXY corp.example:3128'; }"
        let server = try PACFileServer()
        defer { server.stop() }
        server.respond(.init(status: 200, body: Data(script.utf8)), for: "/proxy.pac")
        server.respond(.init(status: 404, body: Data(script.utf8)), for: "/missing.pac")
        server.respond(.init(status: 200, body: Data("<html>Sign in</html>".utf8)), for: "/portal.pac")
        server.respond(.init(status: 200, body: Data(repeating: 0x20, count: PACScriptCache.maximumSize) + Data(script.utf8)), for: "/large.pac")

        let target = "https://github.com/desktop/desktop.git"
        #expect(await Self.resolve(target, Self.pacURLSettings(server.url("/proxy.pac"))) == "http://corp.example:3128")
        for path in ["/missing.pac", "/portal.pac", "/large.pac"] {
            #expect(await Self.resolve(target, Self.merging(Self.pacURLSettings(server.url(path)), Self.secure)) == "http://secure.example:8443", "\(path)")
        }
    }

    @Test("keeps a fetched PAC file for a few minutes, by URL")
    func pacFileCache() async throws {
        let server = try PACFileServer()
        defer { server.stop() }
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY first.example:1'; }".utf8)), for: "/proxy.pac")
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY other.example:2'; }".utf8)), for: "/other.pac")

        let clock = TestClock()
        let options = Self.testOptions(scripts: PACScriptCache(lifetime: 300, now: { clock.now() }))
        let settings = Self.pacURLSettings(server.url("/proxy.pac"))
        let target = "https://github.com/desktop/desktop.git"

        #expect(await Self.resolve(target, settings, options: options) == "http://first.example:1")
        #expect(await Self.resolve("http://example.com/repository.git", settings, options: options) == "http://first.example:1")
        #expect(server.requests("/proxy.pac") == 1)

        // A changed file is fetched once the cached one is too old.
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY second.example:1'; }".utf8)), for: "/proxy.pac")
        clock.advance(by: 299)
        #expect(await Self.resolve(target, settings, options: options) == "http://first.example:1")
        #expect(server.requests("/proxy.pac") == 1)
        clock.advance(by: 1)
        #expect(await Self.resolve(target, settings, options: options) == "http://second.example:1")
        #expect(server.requests("/proxy.pac") == 2)

        // Another URL is another file.
        #expect(await Self.resolve(target, Self.pacURLSettings(server.url("/other.pac")), options: options) == "http://other.example:2")
        #expect(server.requests("/other.pac") == 1)

        // A failure isn't kept.
        server.respond(.init(status: 500, body: Data()), for: "/flaky.pac")
        let flaky = Self.pacURLSettings(server.url("/flaky.pac"))
        #expect(await Self.resolve(target, flaky, options: options) == nil)
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY back.example:1'; }".utf8)), for: "/flaky.pac")
        #expect(await Self.resolve(target, flaky, options: options) == "http://back.example:1")
        #expect(server.requests("/flaky.pac") == 2)
    }

    @Test("decodes a PAC file with its character set, else its byte order mark, else ISO-8859-1")
    func pacFileEncodings() {
        let text = "// caf\u{e9}\nfunction FindProxyForURL() {}"
        #expect(PACScriptCache.decode(Data(text.utf8), charset: "utf-8") == text)
        #expect(PACScriptCache.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), charset: nil) == text)
        #expect(PACScriptCache.decode(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!, charset: nil) == text)
        #expect(PACScriptCache.decode(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!, charset: nil) == text)
        #expect(PACScriptCache.decode(text.data(using: .isoLatin1)!, charset: nil) == text)
        #expect(PACScriptCache.decode(Data(text.utf8), charset: nil) == "// caf\u{c3}\u{a9}\nfunction FindProxyForURL() {}")
        #expect(PACScriptCache.decode(text.data(using: .isoLatin1)!, charset: "iso-8859-1") == text)
    }

    @Test("automatic proxy discovery runs before the PAC file, which runs when discovery finds nothing")
    func discovery() async throws {
        let server = try PACFileServer()
        defer { server.stop() }
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY discovered.example:1'; }".utf8)), for: "/wpad.dat")
        server.respond(.init(status: 200, body: Data("function FindProxyForURL(url, host) { return 'PROXY configured.example:2'; }".utf8)), for: "/proxy.pac")
        let target = "https://github.com/desktop/desktop.git"
        let discovery: [String: any Sendable] = ["ProxyAutoDiscoveryEnable": 1]
        let found = Self.testOptions(discoveryURL: URL(string: server.url("/wpad.dat"))!)

        #expect(await Self.resolve(target, discovery, options: found) == "http://discovered.example:1")
        #expect(await Self.resolve(target, Self.merging(discovery, Self.pacURLSettings(server.url("/proxy.pac"))), options: found) == "http://discovered.example:1")

        // Nothing to discover: the PAC file, else the manual proxies.
        #expect(await Self.resolve(target, Self.merging(discovery, Self.pacURLSettings(server.url("/proxy.pac")))) == "http://configured.example:2")
        #expect(await Self.resolve(target, Self.merging(discovery, Self.secure)) == "http://secure.example:8443")
        #expect(await Self.resolve(target, discovery) == nil)
        #expect(await hostResolves("127.0.0.1", within: 5))
    }

    @Test("gives up on a PAC file that takes too long")
    func timeout() async throws {
        let server = try SilentLocalServer()
        defer { server.close() }

        // The run's own timeout ends it, after the whole timeout: CFNetwork's
        // fails with another error, after a minute.
        let start = ContinuousClock.now
        await #expect(throws: ProxyAutoConfigurationTimeoutError.self) {
            try await executeProxyAutoConfiguration(
                .url(URL(string: "http://127.0.0.1:\(server.port)/proxy.pac")!),
                for: URL(string: "https://github.com")!,
                timeout: 0.5
            )
        }
        #expect(ContinuousClock.now - start >= .milliseconds(500))

        // Resolving gives up on fetching the PAC file once the timeout has
        // passed, and uses the manual proxy.
        let settings = Self.merging(Self.pacURLSettings("http://127.0.0.1:\(server.port)/proxy.pac"), Self.secure)
        let fetchStart = ContinuousClock.now
        #expect(await Self.resolve("https://github.com/desktop/desktop.git", settings, options: Self.testOptions(timeout: 0.5)) == "http://secure.example:8443")
        #expect(ContinuousClock.now - fetchStart >= .milliseconds(500))
    }

    @Test("stops a PAC file's run when the task is cancelled", .hangGuard(minutes: 5))
    func cancellation() async throws {
        let server = try SilentLocalServer()
        defer { server.close() }

        // The run's own timeout is longer than the hang guard's: without the
        // cancellation, the run ends with another error once CFNetwork gives
        // up on the PAC file, after a minute, or not before the guard.
        let task = Task {
            try await executeProxyAutoConfiguration(
                .url(URL(string: "http://127.0.0.1:\(server.port)/proxy.pac")!),
                for: URL(string: "https://github.com")!,
                timeout: 3600
            )
        }
        // CFNetwork is fetching the PAC file, on the run loop the
        // cancellation stops.
        await server.waitForConnection()
        task.cancel()

        let result = try await task.resultUnlessCancelled
        #expect(throws: CancellationError.self) {
            try result.get()
        }
    }
}

/// A server address that refuses connections: a privileged port, which
/// no test can listen on, and which nothing on a Mac serves.
private let refusingServer = "http://127.0.0.1:1"

/// Binds a listening TCP socket to a free port on 127.0.0.1.
private func listeningSocket() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, 16) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(descriptor)
        throw error
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
}

/// A TCP server on 127.0.0.1 that accepts connections (in the kernel's
/// backlog) but never answers.
private final class SilentLocalServer: Sendable {
    let port: UInt16
    private let descriptor: Int32
    /// The connections `waitForConnection()` accepted, closed with the server.
    private let accepted = Mutex<[Int32]>([])

    init() throws {
        let listening = try listeningSocket()
        descriptor = listening.descriptor
        port = listening.port
    }

    /// Returns once a client has connected, and keeps the connection open
    /// without answering. The blocking accept runs on a thread of its own,
    /// off the concurrency pool and dispatch's.
    func waitForConnection() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                let connection = accept(self.descriptor, nil, nil)
                if connection >= 0 {
                    self.accepted.withLock { $0.append(connection) }
                }
                continuation.resume()
            }
        }
    }

    func close() {
        for connection in accepted.withLock({ $0 }) {
            Darwin.close(connection)
        }
        Darwin.close(descriptor)
    }
}

/// An HTTP server on 127.0.0.1 that answers each path with a set response
/// (404 for others) and counts the requests for each path. It accepts on a
/// thread of its own and answers each connection on another, off the
/// concurrency pool and dispatch's (whose threads other tests' blocking
/// work can hold), until `stop()`.
private final class PACFileServer: Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
    }

    private struct State {
        var responses: [String: Response] = [:]
        var requests: [String: Int] = [:]
    }

    let port: UInt16
    /// Written to by `stop()` to wake the accepting thread.
    private let wakeWriter: Int32
    private let state = Mutex(State())

    init() throws {
        let (descriptor, port) = try listeningSocket()
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for end in wake {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        self.port = port
        wakeWriter = wake[1]
        let wakeReader = wake[0]
        Thread.detachNewThread {
            self.acceptConnections(descriptor, wakeReader: wakeReader)
        }
    }

    func stop() {
        var byte: UInt8 = 0
        _ = write(wakeWriter, &byte, 1)
    }

    /// Accepts connections until `stop()`, then closes the sockets.
    private func acceptConnections(_ descriptor: Int32, wakeReader: Int32) {
        defer {
            Darwin.close(descriptor)
            Darwin.close(wakeReader)
            Darwin.close(wakeWriter)
        }
        while true {
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
            ]
            guard poll(&descriptors, 2, -1) >= 0 || errno == EINTR else {
                return
            }
            if descriptors[1].revents != 0 {
                return
            }
            guard descriptors[0].revents != 0 else {
                continue
            }
            let client = accept(descriptor, nil, nil)
            if client >= 0 {
                Thread.detachNewThread {
                    self.serve(client)
                }
            }
        }
    }

    func url(_ path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    func respond(_ response: Response, for path: String) {
        state.withLock { $0.responses[path] = response }
    }

    func requests(_ path: String) -> Int {
        state.withLock { $0.requests[path] ?? 0 }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Array("\r\n\r\n".utf8)
        while received.firstRange(of: terminator) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            received.append(contentsOf: buffer[0..<count])
        }
        let requestLine = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return
        }
        let path = String(parts[1])
        let response = state.withLock { state in
            state.requests[path, default: 0] += 1
            return state.responses[path]
        } ?? Response(status: 404, body: Data())

        var bytes = Array("HTTP/1.1 \(response.status) Status\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(contentsOf: response.body)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(client, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }
}

// Ported from desktop/app/src/lib/resolve-git-proxy.ts
//
// The proxy comes from macOS's proxy settings, read and applied as Chromium
// reads and applies them (net/proxy_resolution/proxy_config_service_mac.cc,
// proxy_chain_util_apple.cc, proxy_config.cc, and
// configured_proxy_resolution_service.cc), and is written as the PAC string
// Chromium reports, which `parsePACString` then turns into proxy URLs. Proxy
// auto-configuration scripts run with CFNetwork (ProxyAutoConfiguration.swift).

import CFNetwork
import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "proxy")

/// Resolves the proxy git should use for `url` from the system's proxy
/// settings, or nil to connect directly. The app installs this as
/// `GitRuntime.resolveProxy` at launch.
public func resolveGitProxy(_ url: String) async -> String? {
    await resolveGitProxy(url, settings: nil, options: ProxyAutoConfigurationOptions())
}

/// `resolveGitProxy` with the proxy settings and how proxy
/// auto-configuration runs as parameters, for tests.
func resolveGitProxy(
    _ url: String,
    settings: SystemProxySettings?,
    options: ProxyAutoConfigurationOptions
) async -> String? {
    let pacString = await resolveProxy(url, settings: settings, options: options)

    guard let proxies = parsePACString(pacString) else {
        return nil
    }

    return proxies.first
}

/// The system's proxy settings, as `CFNetworkCopySystemProxySettings`
/// returns them. Immutable, so safe to share.
struct SystemProxySettings: @unchecked Sendable {
    let dictionary: CFDictionary

    init(_ dictionary: CFDictionary) {
        self.dictionary = dictionary
    }

    init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary as CFDictionary
    }

    static func current() -> SystemProxySettings? {
        CFNetworkCopySystemProxySettings().map { SystemProxySettings($0.takeRetainedValue()) }
    }

    var values: [String: Any] {
        (dictionary as NSDictionary) as? [String: Any] ?? [:]
    }
}

/// The proxies the system's settings choose for `url`, as the PAC string
/// Chromium reports for them (`ProxyList::ToPacString()`), such as
/// `PROXY proxy:8080;DIRECT`.
///
/// With automatic settings (automatic proxy discovery, a PAC file, or a PAC
/// script), the first that loads decides: localhost, loopback, and
/// link-local addresses connect directly, and otherwise the script's
/// answer is the list, or a direct connection when the script fails. When
/// none loads, or there are no automatic settings, the manual proxies
/// apply.
func resolveProxy(
    _ url: String,
    settings: SystemProxySettings? = nil,
    options: ProxyAutoConfigurationOptions = ProxyAutoConfigurationOptions()
) async -> String {
    guard let target = ProxyTarget(url), let settings = settings ?? .current() else {
        return "DIRECT"
    }
    let configuration = ProxyConfiguration(settings)

    if configuration.hasAutomaticSettings {
        if let entries = await configuration.runAutomaticSettings(for: target, options: options) {
            return pacString(for: entries)
        }
        logger.info("No proxy auto-configuration loaded; using the manual proxy settings")
    }

    if let proxy = configuration.manualProxy(for: target) {
        return pacString(for: [.proxy(proxy)])
    }
    return "DIRECT"
}

/// A proxy list as Chromium writes it (`ProxyList::ToPacString()`); an
/// empty list is a direct connection.
func pacString(for entries: [ProxyListEntry]) -> String {
    let specs = entries.map { entry -> String in
        switch entry {
        case .direct:
            "DIRECT"
        case .proxy(let server):
            server.pacResultElement
        }
    }
    return specs.isEmpty ? "DIRECT" : specs.joined(separator: ";")
}

// MARK: - Proxy servers

/// A proxy server as Chromium describes one (`ProxyServer`). macOS's
/// settings and CFNetwork's answers only ever give HTTP and SOCKS5
/// proxies.
struct ProxyServer: Hashable, Sendable {
    enum Scheme: Sendable {
        case http
        case socks5
    }

    let scheme: Scheme
    /// The host, canonical, an IPv6 address without brackets.
    let host: String
    let port: Int

    /// `ProxyServer::FromSchemeHostAndPort`: the host trimmed of spaces,
    /// lowercased, and an IP address in canonical form; a missing port is
    /// the scheme's default (80 or 1080). Nil for a host no URL could carry,
    /// or a port outside 1–65535 (where Chromium would truncate it to 16
    /// bits).
    init?(scheme: Scheme, host rawHost: String, port: Int?) {
        var host = ProxyBypassRules.trimmingASCIIWhitespace(rawHost)
        var bracketed = false
        if host.hasPrefix("["), host.hasSuffix("]"), host.unicodeScalars.count > 2 {
            host = String(host.dropFirst().dropLast())
            bracketed = true
        } else if host.hasPrefix("[") || host.hasSuffix("]") {
            return nil
        }
        if let address = IPAddress(literal: host) {
            host = address.description
        } else {
            // Brackets hold only IPv6 addresses, and digits and dots only
            // IPv4 addresses.
            let forbidden = Set("\u{0}\t\n\r #%/:<>?@[\\]^|;".unicodeScalars)
            guard !bracketed,
                  !host.isEmpty,
                  !host.unicodeScalars.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
                  host.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0.value >= 0x20 && $0.value != 0x7F })
            else {
                return nil
            }
            host = host.lowercased()
        }
        let port = port ?? (scheme == .http ? 80 : 1080)
        guard (1...65535).contains(port) else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// `PROXY host:port` or `SOCKS5 host:port`, with an IPv6 address in
    /// brackets (`ProxyServerToPacResultElement`).
    var pacResultElement: String {
        let host = host.contains(":") ? "[\(host)]" : host
        switch scheme {
        case .http:
            return "PROXY \(host):\(port)"
        case .socks5:
            return "SOCKS5 \(host):\(port)"
        }
    }

    /// The proxy a CFNetwork proxy type names, with its host and port under
    /// the given keys (`ProxyDictionaryToProxyChain`): HTTP proxies, whether
    /// for http or https URLs (macOS's "Secure web proxy" is an HTTP proxy
    /// for https URLs, not one reached over TLS), and SOCKS proxies, always
    /// SOCKS5 (the version CFNetwork names, if any, is ignored). Nil for
    /// other types and unusable hosts and ports.
    init?(type: String?, dictionary: [String: Any], hostKey: String, portKey: String) {
        let scheme: Scheme
        if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
            scheme = .http
        } else if type == (kCFProxyTypeSOCKS as String) {
            scheme = .socks5
        } else {
            return nil
        }
        guard let host = dictionary[hostKey] as? String else {
            return nil
        }
        self.init(scheme: scheme, host: host, port: integer(dictionary[portKey]))
    }
}

/// One entry of a proxy list.
enum ProxyListEntry: Hashable, Sendable {
    case direct
    case proxy(ProxyServer)

    /// A proxy CFNetwork reports (`kCFProxyTypeKey` and friends), or nil for
    /// one Chromium leaves out of the list: an unsupported type (FTP, a
    /// nested PAC file) or an unusable host or port.
    init?(cfNetwork dictionary: [String: Any]) {
        let type = dictionary[kCFProxyTypeKey as String] as? String
        if type == (kCFProxyTypeNone as String) {
            self = .direct
            return
        }
        guard let server = ProxyServer(type: type, dictionary: dictionary, hostKey: kCFProxyHostNameKey as String, portKey: kCFProxyPortNumberKey as String) else {
            return nil
        }
        self = .proxy(server)
    }
}

/// A number's integer value, as `CFNumberGetValue` with
/// `kCFNumberIntType` gives it (a fraction is truncated); nil for anything
/// else, a Boolean included.
private func integer(_ value: Any?) -> Int? {
    guard let value, CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID() else {
        return nil
    }
    return (value as? NSNumber)?.intValue
}

/// Whether a settings flag is on (`GetBoolFromDictionary`): a nonzero
/// number. Booleans count too, which Chromium ignores.
private func flag(_ value: Any?) -> Bool {
    if let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
        return (value as? NSNumber)?.boolValue ?? false
    }
    return (integer(value) ?? 0) != 0
}

// MARK: - The settings

/// macOS's proxy settings as Chromium reads them (`GetCurrentProxyConfig`).
struct ProxyConfiguration: Sendable {
    /// "Auto proxy discovery" (`ProxyAutoDiscoveryEnable`).
    var autoDetect = false
    /// "Automatic proxy configuration" (`ProxyAutoConfigEnable` and
    /// `ProxyAutoConfigURLString`).
    var pacURL: URL?
    /// A PAC script in the settings themselves
    /// (`ProxyAutoConfigJavaScript`, which only configuration profiles
    /// set). Chromium ignores it; CFNetwork runs it, after the PAC file.
    var pacScript: String?
    var httpProxy: ProxyServer?
    var httpsProxy: ProxyServer?
    var ftpProxy: ProxyServer?
    /// The SOCKS proxy, for URLs whose scheme has no proxy of its own.
    var fallbackProxy: ProxyServer?
    var bypassRules = ProxyBypassRules()

    init(_ settings: SystemProxySettings) {
        let values = settings.values

        autoDetect = flag(values[kCFNetworkProxiesProxyAutoDiscoveryEnable as String])

        if flag(values[kCFNetworkProxiesProxyAutoConfigEnable as String]) {
            if let url = values[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String {
                pacURL = URL(string: url)
            }
            if let script = values[kCFNetworkProxiesProxyAutoConfigJavaScript as String] as? String {
                pacScript = script
            }
        }

        func proxy(_ type: CFString, enable: CFString, host: CFString, port: CFString) -> ProxyServer? {
            guard flag(values[enable as String]) else {
                return nil
            }
            return ProxyServer(type: type as String, dictionary: values, hostKey: host as String, portKey: port as String)
        }
        // macOS's FTP proxy is an HTTP proxy for ftp URLs.
        ftpProxy = proxy(kCFProxyTypeHTTP, enable: kCFNetworkProxiesFTPEnable, host: kCFNetworkProxiesFTPProxy, port: kCFNetworkProxiesFTPPort)
        httpProxy = proxy(kCFProxyTypeHTTP, enable: kCFNetworkProxiesHTTPEnable, host: kCFNetworkProxiesHTTPProxy, port: kCFNetworkProxiesHTTPPort)
        httpsProxy = proxy(kCFProxyTypeHTTPS, enable: kCFNetworkProxiesHTTPSEnable, host: kCFNetworkProxiesHTTPSProxy, port: kCFNetworkProxiesHTTPSPort)
        fallbackProxy = proxy(kCFProxyTypeSOCKS, enable: kCFNetworkProxiesSOCKSEnable, host: kCFNetworkProxiesSOCKSProxy, port: kCFNetworkProxiesSOCKSPort)

        for entry in values[kCFNetworkProxiesExceptionsList as String] as? [Any] ?? [] {
            if let entry = entry as? String {
                bypassRules.add(entry)
            }
        }
        if flag(values[kCFNetworkProxiesExcludeSimpleHostnames as String]) {
            bypassRules.prependSimpleHostnames()
        }
    }

    var hasAutomaticSettings: Bool {
        autoDetect || pacURL != nil || pacScript != nil
    }

    /// The manual proxy for `target`, or nil to connect directly
    /// (`ProxyConfig::ProxyRules::Apply`): none without proxies, none for
    /// an exception, else the scheme's proxy or the SOCKS proxy.
    func manualProxy(for target: ProxyTarget) -> ProxyServer? {
        if httpProxy == nil, httpsProxy == nil, ftpProxy == nil, fallbackProxy == nil {
            return nil
        }
        if bypassRules.matches(target) {
            return nil
        }
        let schemeProxy: ProxyServer? = switch target.scheme {
        case "http": httpProxy
        case "https": httpsProxy
        case "ftp": ftpProxy
        default: nil
        }
        return schemeProxy ?? fallbackProxy
    }

    /// Runs the automatic settings for `target`: the proxy list from the
    /// first source that loads (automatic discovery, the PAC file, the PAC
    /// script, in that order), or nil when none does.
    func runAutomaticSettings(for target: ProxyTarget, options: ProxyAutoConfigurationOptions) async -> [ProxyListEntry]? {
        var sources: [ProxyAutoConfigurationSource] = []
        if autoDetect {
            sources.append(.discovery(options.discoveryURL))
        }
        if let pacURL {
            sources.append(.url(pacURL))
        }
        if let pacScript {
            sources.append(.script(pacScript))
        }

        for source in sources {
            guard !Task.isCancelled else {
                return nil
            }
            switch await source.load(options: options) {
            case .script(let script):
                if ProxyBypassRules.matchesImplicitRules(target) {
                    return [.direct]
                }
                do {
                    return try await executeProxyAutoConfiguration(.script(script), for: target.sanitizedURL, timeout: options.timeout)
                } catch {
                    // A failing script connects directly, as Chromium's
                    // resolver falls back to DIRECT on a script error.
                    logger.error("Failed running the proxy auto-configuration script: \(String(describing: error), privacy: .public)")
                    return [.direct]
                }
            case .unfetched(let url):
                if ProxyBypassRules.matchesImplicitRules(target) {
                    return [.direct]
                }
                do {
                    return try await executeProxyAutoConfiguration(.url(url), for: target.sanitizedURL, timeout: options.timeout)
                } catch {
                    logger.error("Failed resolving proxy: \(String(describing: error), privacy: .public)")
                }
            case .failed(let reason):
                logger.error("Proxy auto-configuration didn't load: \(reason, privacy: .public)")
            }
        }
        return nil
    }
}

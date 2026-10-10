// Ported in part from Chromium's net/proxy_resolution/proxy_host_matching_rules.cc,
// net/base/scheme_host_port_matcher_rule.cc, and base/strings/pattern.cc:
// which URLs skip the proxy. The macOS proxy settings' exceptions list
// is read as Chromium reads it, which isn't how CFNetwork reads it
// (CFNetwork doesn't trim the entries, and ignores `*`, `<local>`, schemes,
// ports, and wildcards other than a leading `*.`), and localhost,
// loopback, and link-local addresses always connect directly.

import Darwin
import Foundation

/// A URL a proxy is resolved for, as Chromium's `GURL` describes it: its
/// scheme, host, and port.
struct ProxyTarget: Sendable, Equatable {
    /// The scheme, lowercased.
    let scheme: String
    /// The host, lowercased, with an IPv4 address in dotted form and an
    /// IPv6 address without brackets.
    let host: String
    /// The host's address when it is an IP address.
    let address: IPAddress?
    /// The port, or the scheme's default.
    let effectivePort: Int?
    /// The URL a proxy auto-configuration script sees: without
    /// credentials or fragment, and for https without path or query
    /// (`SanitizeUrlForProxyResolution`).
    let sanitizedURL: URL

    init?(_ string: String) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              var host = components.host, !host.isEmpty
        else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        host = host.lowercased()
        let address = IPAddress(literal: host)
        if let address {
            host = address.description
        }
        self.scheme = scheme
        self.host = host
        self.address = address
        let defaultPort = Self.defaultPorts[scheme]
        effectivePort = components.port ?? defaultPort

        var sanitized = "\(scheme)://\(address?.isIPv6 == true ? "[\(host)]" : host)"
        if let port = components.port, port != defaultPort {
            sanitized += ":\(port)"
        }
        if scheme == "https" || scheme == "wss" {
            sanitized += "/"
        } else {
            sanitized += components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            if let query = components.percentEncodedQuery {
                sanitized += "?\(query)"
            }
        }
        guard let sanitizedURL = URL(string: sanitized) else {
            return nil
        }
        self.sanitizedURL = sanitizedURL
    }

    private static let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]

    /// The host as `GURL::host()` gives it: an IPv6 address in brackets.
    var urlHost: String {
        address?.isIPv6 == true ? "[\(host)]" : host
    }
}

/// An IPv4 or IPv6 address.
struct IPAddress: Sendable, Hashable, CustomStringConvertible {
    let bytes: [UInt8]

    var isIPv4: Bool { bytes.count == 4 }
    var isIPv6: Bool { bytes.count == 16 }

    /// An IP literal as `IPAddress::AssignFromIPLiteral` reads one: IPv6
    /// when it has a colon (without brackets), else IPv4 in any of the
    /// forms a URL may write one in (`127.1`, `0x7f.0.0.1`).
    init?(literal: String) {
        if literal.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, literal, &address) == 1 else {
                return nil
            }
            bytes = withUnsafeBytes(of: &address) { Array($0) }
            return
        }
        // inet_aton reads the same numeric forms as a URL's IPv4 parser,
        // but ignores what follows a space.
        guard !literal.isEmpty, literal.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isASCIIHexDigit || $0 == "x" || $0 == "X" || $0 == ".") }) else {
            return nil
        }
        var address = in_addr()
        guard inet_aton(literal, &address) == 1 else {
            return nil
        }
        bytes = withUnsafeBytes(of: &address) { Array($0) }
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var copy = bytes
        let family = isIPv4 ? AF_INET : AF_INET6
        guard inet_ntop(family, &copy, &buffer, socklen_t(buffer.count)) != nil else {
            return ""
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 127.0.0.0/8 or ::1.
    var isLoopback: Bool {
        if isIPv4 {
            return bytes[0] == 127
        }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
    }

    /// 169.254.0.0/16, its IPv4-mapped form, or fe80::/10.
    var isLinkLocal: Bool {
        if isIPv4 {
            return bytes[0] == 169 && bytes[1] == 254
        }
        if isIPv4MappedIPv6 {
            return bytes[12] == 169 && bytes[13] == 254
        }
        return bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
    }

    /// ::ffff:0:0/96.
    var isIPv4MappedIPv6: Bool {
        isIPv6 && bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    /// Whether the address is in `prefix`/`bits`, comparing an IPv4 address
    /// with an IPv6 prefix (or the other way round) in its IPv4-mapped form
    /// (`IPAddressMatchesPrefix`).
    func matches(prefix: IPAddress, bits: Int) -> Bool {
        if bytes.count != prefix.bytes.count {
            if isIPv4 {
                return IPAddress(bytes: Self.mappedPrefix + bytes).matches(prefix: prefix, bits: bits)
            }
            return matches(prefix: IPAddress(bytes: Self.mappedPrefix + prefix.bytes), bits: 96 + bits)
        }
        let whole = bits / 8
        guard bytes.prefix(whole) == prefix.bytes.prefix(whole) else {
            return false
        }
        let remaining = bits % 8
        if remaining != 0 {
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
            return bytes[whole] & mask == prefix.bytes[whole] & mask
        }
        return true
    }

    private static let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
}

/// The hosts that connect without the proxy: the settings' exceptions, in
/// order, each later one overriding the ones before it, then the implicit
/// rules (`ProxyHostMatchingRules`).
struct ProxyBypassRules: Sendable {
    enum Rule: Sendable, Equatable {
        /// `<local>`: host names without a dot.
        case simpleHostnames
        /// `<-loopback>`: proxies localhost, loopback, and link-local
        /// addresses after all.
        case subtractImplicit
        /// A host name with `*` and `?` wildcards (a leading `.` is `*.`),
        /// optionally for one scheme and port.
        case hostnamePattern(scheme: String?, pattern: String, port: Int?)
        /// An IP address, optionally for one scheme and port.
        case ipHost(scheme: String?, address: IPAddress, port: Int?)
        /// An IP address range in CIDR notation, optionally for one scheme.
        case ipBlock(scheme: String?, prefix: IPAddress, bits: Int)
    }

    private enum Verdict {
        case include
        case exclude
        case noMatch
    }

    private(set) var rules: [Rule] = []

    /// Adds an exceptions-list entry, if Chromium can read it
    /// (`AddRuleFromString`).
    mutating func add(_ entry: String) {
        if let rule = Self.rule(entry) {
            rules.append(rule)
        }
    }

    /// "Exclude simple hostnames" (`PrependRuleToBypassSimpleHostnames`).
    mutating func prependSimpleHostnames() {
        rules.insert(.simpleHostnames, at: 0)
    }

    /// Whether `target` connects without the proxy.
    func matches(_ target: ProxyTarget) -> Bool {
        for rule in rules.reversed() {
            switch Self.evaluate(rule, target) {
            case .include:
                return true
            case .exclude:
                return false
            case .noMatch:
                continue
            }
        }
        return Self.matchesImplicitRules(target)
    }

    /// Localhost (`localhost`, `*.localhost`, with or without a final dot),
    /// loopback addresses, and link-local addresses.
    static func matchesImplicitRules(_ target: ProxyTarget) -> Bool {
        if let address = target.address {
            if address.isLoopback || address.isLinkLocal {
                return true
            }
            return address.isIPv4MappedIPv6 && address.bytes[12] == 127
        }
        var host = Substring(target.host)
        if host.hasSuffix(".") {
            host = host.dropLast()
        }
        return host == "localhost" || host.hasSuffix(".localhost")
    }

    private static func evaluate(_ rule: Rule, _ target: ProxyTarget) -> Verdict {
        switch rule {
        case .simpleHostnames:
            return !target.host.contains(".") && target.address == nil ? .include : .noMatch
        case .subtractImplicit:
            return matchesImplicitRules(target) ? .exclude : .noMatch
        case .hostnamePattern(let scheme, let pattern, let port):
            if let port, target.effectivePort != port {
                return .noMatch
            }
            if let scheme, target.scheme != scheme {
                return .noMatch
            }
            return matchPattern(target.urlHost, pattern) ? .include : .noMatch
        case .ipHost(let scheme, let address, let port):
            if let port, target.effectivePort != port {
                return .noMatch
            }
            if let scheme, target.scheme != scheme {
                return .noMatch
            }
            return target.address == address ? .include : .noMatch
        case .ipBlock(let scheme, let prefix, let bits):
            guard let address = target.address else {
                return .noMatch
            }
            if let scheme, target.scheme != scheme {
                return .noMatch
            }
            return address.matches(prefix: prefix, bits: bits) ? .include : .noMatch
        }
    }

    // MARK: Reading entries

    /// An exceptions-list entry as a rule (`ParseRule` and
    /// `SchemeHostPortMatcherRule::FromUntrimmedRawString`), or nil for one
    /// Chromium can't read.
    static func rule(_ entry: String) -> Rule? {
        var raw = trimmingASCIIWhitespace(entry)
        if raw.lowercased() == "<local>" {
            return .simpleHostnames
        }
        if raw.lowercased() == "<-loopback>" {
            return .subtractImplicit
        }

        var scheme: String?
        if let separator = raw.range(of: "://") {
            let name = String(raw[..<separator.lowerBound])
            guard !name.isEmpty else {
                return nil
            }
            scheme = name.lowercased()
            raw = String(raw[separator.upperBound...])
        }
        guard !raw.isEmpty else {
            return nil
        }

        // A slash is probably a CIDR block.
        if raw.contains("/") {
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map { trimmingASCIIWhitespace(String($0)) }
            guard parts.count == 2,
                  let prefix = IPAddress(literal: parts[0]),
                  let bits = parseNonNegativeInteger(parts[1]),
                  bits <= prefix.bytes.count * 8
            else {
                return nil
            }
            return .ipBlock(scheme: scheme, prefix: prefix, bits: bits)
        }

        // An IP address, with or without a port.
        if let parsed = hostAndPort(raw), let address = IPAddress(literal: parsed.host) {
            return .ipHost(scheme: scheme, address: address, port: parsed.port == 0 ? nil : parsed.port)
        }

        // Otherwise a host name pattern, with or without a port.
        var port: Int?
        if let colon = raw.lastIndex(of: ":") {
            guard let number = parseNonNegativeInteger(String(raw[raw.index(after: colon)...])), number <= 0xFFFF else {
                return nil
            }
            port = number
            raw = String(raw[..<colon])
        }
        let pattern = raw.hasPrefix(".") ? "*" + raw : raw
        return .hostnamePattern(scheme: scheme, pattern: pattern.lowercased(), port: port)
    }

    /// `host[:port]` or `[ipv6][:port]`, as `ParseHostAndPort` splits it,
    /// or nil when it isn't one.
    private static func hostAndPort(_ input: String) -> (host: String, port: Int?)? {
        var host: Substring
        var portText: Substring?
        if input.hasPrefix("[") {
            guard let close = input.firstIndex(of: "]") else {
                return nil
            }
            host = input[input.index(after: input.startIndex)..<close]
            let rest = input[input.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else {
                    return nil
                }
                portText = rest.dropFirst()
            }
            guard IPAddress(literal: String(host))?.isIPv6 == true else {
                return nil
            }
        } else if let colon = input.lastIndex(of: ":") {
            host = input[..<colon]
            portText = input[input.index(after: colon)...]
        } else {
            host = Substring(input)
        }
        guard !host.isEmpty, !host.contains("@") else {
            return nil
        }
        var port: Int?
        if let portText {
            guard let number = parseNonNegativeInteger(String(portText)), number <= 0xFFFF else {
                return nil
            }
            port = number
        }
        return (String(host), port)
    }

    private static func parseNonNegativeInteger(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 10, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return Int(text)
    }

    static func trimmingASCIIWhitespace(_ text: String) -> String {
        let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !whitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !whitespace.contains($0) })
        else {
            return ""
        }
        return String(scalars[first...last])
    }

    // MARK: Wildcards

    /// Whether `string` matches `pattern`, where `*` matches any run of
    /// characters, `?` zero or one, and `\` escapes either
    /// (`base::MatchPattern`).
    static func matchPattern(_ string: String, _ pattern: String) -> Bool {
        let eval = Array(string.unicodeScalars)
        let pattern = Array(pattern.unicodeScalars)
        var evalIndex = 0
        var patternIndex = 0
        repeat {
            let maximumDistance = eatWildcards(pattern, &patternIndex)
            if !searchForChars(pattern, &patternIndex, eval, &evalIndex, maximumDistance) {
                return false
            }
        } while patternIndex != pattern.count
        return true
    }

    /// Skips a run of wildcards: how many characters they may match, or -1
    /// for any number.
    private static func eatWildcards(_ pattern: [Unicode.Scalar], _ index: inout Int) -> Int {
        var questionMarks = 0
        var asterisk = false
        while index < pattern.count {
            if pattern[index] == "?" {
                questionMarks += 1
            } else if pattern[index] == "*" {
                asterisk = true
            } else {
                break
            }
            index += 1
        }
        return asterisk ? -1 : questionMarks
    }

    /// Finds the pattern's next run of literal characters in `eval`, at
    /// most `maximumDistance` characters along (any distance when it's
    /// negative).
    private static func searchForChars(
        _ pattern: [Unicode.Scalar],
        _ patternIndex: inout Int,
        _ eval: [Unicode.Scalar],
        _ evalIndex: inout Int,
        _ maximumDistance: Int
    ) -> Bool {
        let patternStart = patternIndex
        var evalStart = evalIndex
        var distance = maximumDistance
        var escape = false
        while true {
            if patternIndex == pattern.count {
                if evalIndex == eval.count {
                    return true
                }
            } else {
                let character = pattern[patternIndex]
                if !escape, character == "*" || character == "?" {
                    return true
                }
                if !escape, character == "\\" {
                    escape = true
                    patternIndex += 1
                    continue
                }
                escape = false
                if evalIndex == eval.count {
                    return false
                }
                if character == eval[evalIndex] {
                    patternIndex += 1
                    evalIndex += 1
                    continue
                }
            }
            // A mismatch: try again one character along, if that's allowed.
            if distance == 0 {
                return false
            }
            distance -= 1
            patternIndex = patternStart
            if evalStart < eval.count {
                evalStart += 1
            }
            evalIndex = evalStart
        }
    }
}

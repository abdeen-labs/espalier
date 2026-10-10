import Foundation

/// The URL could not be parsed (JavaScript's `new URL()` throws a
/// `TypeError`).
public struct JSURLError: Error, Equatable, CustomStringConvertible {
    public let input: String

    public init(input: String) {
        self.input = input
    }

    public var description: String { "Invalid URL: \(input)" }
}

/// The parts of JavaScript's WHATWG `URL` that Espalier relies on, for
/// hierarchical URLs such as `https://user@host:port/path?query#hash`.
///
/// Parsing uses `URLComponents` and then normalizes the way WHATWG URLs do
/// for special schemes (`http`, `https`, `ws`, `wss`, `ftp`, `file`): the
/// scheme and host are lowercased, a default port is dropped, and an empty
/// path becomes `/`. Percent-encoding is kept as written. Inputs WHATWG
/// repairs but `URLComponents` rejects (unencoded spaces, for example) throw,
/// so build such URLs from encoded parts.
public struct JSURL: Sendable, Equatable, CustomStringConvertible {
    /// `url.protocol`: the scheme, lowercased, followed by a colon.
    public var `protocol`: String

    /// `url.username`, percent-encoded.
    public var username: String

    /// `url.password`, percent-encoded.
    public var password: String

    /// `url.hostname`: the host without the port, lowercased for special
    /// schemes. IPv6 addresses keep their brackets.
    public var hostname: String

    /// `url.port`: empty when absent or the scheme's default.
    public var port: String

    /// `url.pathname`.
    public var pathname: String

    /// `url.search`: empty, or the query with a leading `?`.
    public var search: String

    /// `url.hash`: empty, or the fragment with a leading `#`.
    public var hash: String

    /// `new URL(string)`.
    public init(_ string: String) throws(JSURLError) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.percentEncodedHost
        else {
            throw JSURLError(input: string)
        }

        let lowercasedScheme = scheme.lowercased()
        let isSpecial = Self.defaultPorts.keys.contains(lowercasedScheme) || lowercasedScheme == "file"

        self.protocol = lowercasedScheme + ":"
        username = components.percentEncodedUser ?? ""
        password = components.percentEncodedPassword ?? ""

        var hostname = isSpecial ? host.lowercased() : host
        if hostname.contains(":"), !hostname.hasPrefix("[") {
            hostname = "[\(hostname)]"
        }
        self.hostname = hostname

        if let explicitPort = components.port, explicitPort != Self.defaultPorts[lowercasedScheme] {
            port = String(explicitPort)
        } else {
            port = ""
        }

        let path = components.percentEncodedPath
        pathname = path.isEmpty && isSpecial ? "/" : path
        search = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? ""
        hash = components.percentEncodedFragment.flatMap { $0.isEmpty ? nil : "#" + $0 } ?? ""
    }

    /// `url.host`: the hostname and, when it isn't the default, the port.
    public var host: String {
        port.isEmpty ? hostname : "\(hostname):\(port)"
    }

    /// `url.origin` for special schemes: the protocol, host, and port.
    public var origin: String {
        "\(self.protocol)//\(host)"
    }

    /// `url.href`, which is also `url.toString()`.
    public var href: String {
        var userInfo = ""
        if !username.isEmpty || !password.isEmpty {
            userInfo = username + (password.isEmpty ? "" : ":" + password) + "@"
        }
        return "\(self.protocol)//\(userInfo)\(host)\(pathname)\(search)\(hash)"
    }

    public var description: String { href }

    private static let defaultPorts: [String: Int] = [
        "http": 80,
        "https": 443,
        "ws": 80,
        "wss": 443,
        "ftp": 21,
    ]

    /// JavaScript's `encodeURIComponent`: percent-encodes everything except
    /// ASCII letters, digits, and `-_.!~*'()`.
    public static func encodeURIComponent(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? string
    }

    private static let uriComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
}

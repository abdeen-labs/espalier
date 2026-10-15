import Foundation

// Helpers with the semantics of the JavaScript and Node.js built-ins
// (`encodeURIComponent`, `parseInt`, `url.parse`, `new URL`). Ported code
// calls these so its string handling matches JavaScript's byte for byte.

/// The characters `encodeURIComponent` leaves alone.
private let uriComponentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

/// JavaScript's `encodeURIComponent`.
public func encodeURIComponent(_ string: String) -> String {
    string.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? string
}

/// JavaScript's `parseInt(string, 10)`: optional leading whitespace and sign,
/// then as many decimal digits as there are. `nil` where JavaScript returns
/// `NaN`.
func parseInt(_ string: String) -> Int? {
    var scalars = Substring(string).drop(while: { $0.isWhitespace })
    var negative = false
    if let sign = scalars.first, sign == "-" || sign == "+" {
        negative = sign == "-"
        scalars = scalars.dropFirst()
    }
    let digits = scalars.prefix(while: { $0.isASCII && $0.isNumber })
    guard !digits.isEmpty, let value = Int(digits) else { return nil }
    return negative ? -value : value
}

/// The parts of a URL, as Node's legacy `url.parse()` and WHATWG `new URL()`
/// report them.
struct ParsedURL {
    /// The scheme with its trailing colon (`https:`), as Node reports it.
    let `protocol`: String?

    /// The host name, lowercased, without a port.
    let hostname: String?

    /// The port, unless it's the scheme's default (443 for HTTPS, 80 for
    /// HTTP), as WHATWG `new URL().port` reports it.
    let port: Int?

    /// The host name and port, if any (`ghe.io:9000`); without the scheme's
    /// default port, as WHATWG `new URL().host` reports it.
    let host: String?

    /// The percent-encoded path.
    let pathname: String

    /// The percent-encoded query string, without its leading `?`.
    let query: String?

    /// Node's `path`: the path name followed by the search string.
    var path: String {
        query.map { "\(pathname)?\($0)" } ?? pathname
    }

    init(_ string: String) {
        let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = components?.scheme?.lowercased()
        `protocol` = scheme.map { "\($0):" }
        let hostname = components?.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.hostname = hostname
        let port = components?.port.flatMap { port in
            scheme == "https" && port == 443 || scheme == "http" && port == 80 ? nil : port
        }
        self.port = port
        if let hostname, let port {
            host = "\(hostname):\(port)"
        } else {
            host = hostname
        }
        pathname = components?.percentEncodedPath ?? ""
        query = components?.percentEncodedQuery
    }
}

/// Node's `url.parse(string).hostname`, lowercased; `nil` when the URL has no
/// host. WHATWG `new URL(string).hostname` gives the same answer for every
/// valid URL GitHubKit parses.
func hostname(of string: String) -> String? {
    ParsedURL(string).hostname
}

// Ported from desktop/app/src/lib/parse-pac-string.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "proxy")

/// `/\s*;\s*/`
private let specSeparatorPattern = JSCompat.regex("\(JSCompat.whitespace)*;\(JSCompat.whitespace)*")

/// Parse a Proxy Auto Configuration (PAC) string into one or more cURL-
/// compatible proxy URLs.
///
/// See https://developer.mozilla.org/en-US/docs/Web/HTTP/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_(PAC)_file
/// for a good primer on PAC files.
///
/// Note that this method is not intended to be a fully compliant PAC parser
/// nor is it intended to handle common PAC string mistakes (such as including
/// the protocol in the host portion of the spec). It translates the PAC
/// strings Chromium produces for its proxy state (`ProxyList::ToPacString()`),
/// which `resolveProxy` produces from the system's proxy settings.
///
/// Proxy protocols not supported by cURL (QUIC) will be silently omitted.
///
/// PAC string BNF
/// --------------
///
/// From https://dxr.mozilla.org/mozilla-central/source/netwerk/base/ProxyAutoConfig.h#48
///
///     result      = proxy-spec *( proxy-sep proxy-spec )
///     proxy-spec  = direct-type | proxy-type LWS proxy-host [":" proxy-port]
///     direct-type = "DIRECT"
///     proxy-type  = "PROXY" | "HTTP" | "HTTPS" | "SOCKS" | "SOCKS4" | "SOCKS5"
///     proxy-sep   = ";" LWS
///     proxy-host  = hostname | ipv4-address-literal
///     proxy-port  = <any 16-bit unsigned integer>
///     LWS         = *( SP | HT )
///     SP          = <US-ASCII SP, space (32)>
///     HT          = <US-ASCII HT, horizontal-tab (9)>
///
/// NOTE: direct-type and proxy-type are case insensitive
/// NOTE: SOCKS implies SOCKS4
///
/// Examples:
///
///     "PROXY proxy1.foo.com:8080; PROXY proxy2.foo.com:8080; DIRECT"
///     "SOCKS socksproxy"
///     "DIRECT"
///
/// Other notes:
///
/// From https://curl.haxx.se/libcurl/c/CURLOPT_PROXY.html
///    When you set a host name to use, do not assume that there's
///    any particular single port number used widely for proxies.
///    Specify it!
public func parsePACString(_ pacString: String) -> [String]? {
    // Happy path, this will be the case for the vast majority of users
    if JSCompat.strictEquals(pacString, "DIRECT") {
        return nil
    }

    let trimmed = JSCompat.trim(pacString)
    let specs = splitByRegex(trimmed, specSeparatorPattern)
    var urls: [String] = []

    for spec in specs {
        // No point in continuing after we get a DIRECT since we
        // have no way of implementing a fallback logic in cURL/Git
        if startsWithDirect(spec) {
            break
        }

        let parts = splitOnWhitespace(spec, limit: 2)

        if parts.count == 2 {
            let (proto, endpoint) = (parts[0], parts[1])

            if let url = urlFromProtocolAndEndpoint(proto, endpoint) {
                urls.append(url)
            } else {
                logger.warning("Skipping proxy spec: \(spec, privacy: .public)")
            }
        }
    }

    return urls.isEmpty ? nil : urls
}

private func urlFromProtocolAndEndpoint(_ proto: String, _ endpoint: String) -> String? {
    // Note that we explicitly want to preserve the port number (if provided).
    // If we run these through a URL parser it will attempt to be smart and
    // remove the default port. So if a PAC string specified `PROXY myproxy:80`
    // we'll generate `http://myproxy:80` which would get turned into
    // `http://myproxy` by URL libraries since they think 80 is redundant. In
    // our case it's not redundant though because cURL defaults to port 1080
    // for all proxy protocols, see
    //
    // https://curl.haxx.se/libcurl/c/CURLOPT_PROXY.html
    //
    // HTTP is an alias for PROXY (or vice versa idk). Chromium never produces
    // 'HTTP', based on a reading of
    // https://github.com/chromium/chromium/blob/2ca8c5037021/net/base/proxy_server.cc#L164-L184
    // but we'll support it nonetheless.
    //
    // SOCKS is an alias for SOCKS4
    switch jsLowercased(proto) {
    case "proxy", "http":
        return "http://\(endpoint)"
    case "https":
        return "https://\(endpoint)"
    case "socks", "socks4":
        return "socks4://\(endpoint)"
    case "socks5":
        return "socks5://\(endpoint)"
    default:
        return nil
    }
}

/// `string.toLowerCase()` for comparing against ASCII keywords.
private func jsLowercased(_ string: String) -> String {
    string.lowercased()
}

/// `/^direct/i`. JavaScript's case-insensitive matching never maps a
/// non-ASCII character onto an ASCII one, so this compares ASCII only.
private func startsWithDirect(_ spec: String) -> Bool {
    let prefix = Array(spec.unicodeScalars.prefix(6))
    guard prefix.count == 6 else {
        return false
    }
    return zip(prefix, "direct".unicodeScalars).allSatisfy { scalar, expected in
        scalar.isASCII && (scalar.value | 0x20) == expected.value
    }
}

/// `string.split(regex)`: the pieces between the matches, keeping empty ones.
private func splitByRegex(_ string: String, _ regex: NSRegularExpression) -> [String] {
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    var pieces: [String] = []
    var start = string.startIndex
    for match in regex.matches(in: string, range: range) {
        guard let matchRange = Range(match.range, in: string) else { continue }
        // JavaScript skips an empty match at the start of the string or at
        // the end of the previous match; this pattern always matches ';'.
        pieces.append(String(string[start..<matchRange.lowerBound]))
        start = matchRange.upperBound
    }
    pieces.append(String(string[start...]))
    return pieces
}

/// `string.split(/\s+/, limit)`: the pieces between runs of JavaScript
/// whitespace, keeping empty ones, at most `limit` of them.
private func splitOnWhitespace(_ string: String, limit: Int) -> [String] {
    var pieces: [String] = []
    var current = String.UnicodeScalarView()
    var scalars = string.unicodeScalars[...]
    while let scalar = scalars.first {
        if JSCompat.isWhitespace(scalar) {
            pieces.append(String(current))
            if pieces.count == limit {
                return pieces
            }
            current = String.UnicodeScalarView()
            scalars = scalars.drop(while: JSCompat.isWhitespace)
        } else {
            current.append(scalar)
            scalars = scalars.dropFirst()
        }
    }
    pieces.append(String(current))
    return Array(pieces.prefix(limit))
}

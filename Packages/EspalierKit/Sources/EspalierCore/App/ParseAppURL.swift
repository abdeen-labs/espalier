// Ported from desktop/app/src/lib/parse-app-url.ts
//
// `NodeLegacyURL` below is the part of Node's legacy `url.parse(url, true)`
// these URLs go through. There's no `oauth` action: signing in uses the
// device flow, which has no browser callback.

import EspalierSupport
import Foundation
import GitKit

/// An "open repository" link:
/// `espalier://openRepo/<url>?branch=&pr=&filepath=`.
public struct OpenRepositoryFromURLAction: Sendable, Equatable {
    /// the remote repository location associated with the "Open in Espalier"
    /// action
    public let url: String

    /// the optional branch name which should be checked out. use the default
    /// branch otherwise.
    public let branch: String?

    /// the pull request number, if pull request originates from a fork of the
    /// repository
    public let pr: String?

    /// the file to open after cloning the repository
    public let filepath: String?

    public init(url: String, branch: String? = nil, pr: String? = nil, filepath: String? = nil) {
        self.url = url
        self.branch = branch
        self.pr = pr
        self.filepath = filepath
    }
}

/// What an app URL asks for.
public enum URLActionType: Sendable, Equatable {
    case openRepositoryFromURL(OpenRepositoryFromURLAction)
    /// Anything else.
    case unknown(url: String)

    /// The action's name: `open-repository-from-url` or `unknown`.
    public var name: String {
        switch self {
        case .openRepositoryFromURL: "open-repository-from-url"
        case .unknown: "unknown"
        }
    }
}

/// Parses an app URL. Only the host names the action (case-insensitively);
/// the scheme isn't checked.
public func parseAppURL(_ url: String) -> URLActionType {
    let parsedURL = NodeLegacyURL(url)
    let unknown = URLActionType.unknown(url: url)
    guard let hostname = parsedURL.hostname, !hostname.isEmpty else {
        return unknown
    }

    let query = parsedURL.query

    let actionName = JSCompat.toLowerCase(hostname)

    // we require something resembling a URL first
    // - bail out if it's not defined
    // - bail out if you only have `/`
    guard let pathName = parsedURL.pathname, pathName.utf16.count > 1 else {
        return unknown
    }

    // Trim the trailing / from the URL
    let parsedPath = JSCompat.dropFirst(pathName, 1)

    if JSCompat.strictEquals(actionName, "openrepo") {
        let pr = getQueryStringValue(query, "pr")
        let branch = getQueryStringValue(query, "branch")
        let filepath = getQueryStringValue(query, "filepath")

        if let pr {
            // `/^\d+$/`
            if !isDigits(pr) {
                return unknown
            }

            // we also expect the branch for a forked PR to be a given ref format
            if let branch, !(JSCompat.startsWith(branch, "pr/") && isDigits(JSCompat.dropFirst(branch, 3))) {
                return unknown
            }
        }

        if let branch, testForInvalidChars(branch) {
            return unknown
        }

        return .openRepositoryFromURL(OpenRepositoryFromURLAction(
            url: parsedPath,
            branch: branch,
            pr: pr,
            filepath: filepath
        ))
    }

    return unknown
}

/// Parse the URL to find a given key in the querystring text: the first
/// value of a repeated key.
private func getQueryStringValue(_ query: [String: [String]], _ key: String) -> String? {
    query[key]?.first
}

/// JavaScript's `/^\d+$/`: one or more ASCII digits.
private func isDigits(_ string: String) -> Bool {
    !string.isEmpty && string.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
}

// MARK: - Node's legacy url.parse

/// The parts of Node's legacy `url.parse(url, true)` that `parseAppURL`
/// reads: the host name (lowercased, without auth or port), the path name,
/// and the query string parsed with `querystring.parse`.
///
/// Node's auto-escaping of characters such as spaces in the path, and its
/// conversion of backslashes, aren't reproduced: the URLs come from macOS as
/// `URL` values, which can't contain them unescaped.
struct NodeLegacyURL: Equatable {
    /// Nil when the URL has no host part (no `//` after the scheme).
    var hostname: String?
    var pathname: String?
    /// Values by key, in the order they appear.
    var query: [String: [String]] = [:]

    init(_ url: String) {
        var rest = Substring(JSCompat.trim(url))

        // `/^[a-z0-9.+-]+:/i`
        var proto: String?
        if let protocolEnd = rest.firstIndex(of: ":"), protocolEnd > rest.startIndex,
           rest[..<protocolEnd].unicodeScalars.allSatisfy(Self.isProtocolCharacter) {
            proto = String(rest[...protocolEnd])
            rest = rest[rest.index(after: protocolEnd)...]
        }
        let isHostless = proto.map { JSCompat.strictEquals(JSCompat.toLowerCase($0), "javascript:") } ?? false

        var slashes = false
        if proto != nil, rest.hasPrefix("//"), !isHostless {
            slashes = true
            rest = rest.dropFirst(2)
        }

        // A host follows the slashes, and, even without them, the protocol
        // of anything but Node's "slashed" protocols (http, https, ...).
        if !isHostless, slashes || proto.map({ !Self.slashedProtocols.contains($0) }) ?? false {
            // The first instance of /, ?, or # ends the host. If there is an
            // @ in the host, characters that can't be in a host name are
            // allowed to the left of the last @, which ends the auth;
            // otherwise the first of them ends the host.
            var hostEnd: String.Index?
            var atSign: String.Index?
            var nonHost: String.Index?
            var index = rest.startIndex
            while index < rest.endIndex {
                switch rest.unicodeScalars[index] {
                case "\t", "\n", "\r", " ", "\"", "%", "'", ";", "<", ">", "\\", "^", "`", "{", "|", "}":
                    if nonHost == nil {
                        nonHost = index
                    }
                case "#", "/", "?":
                    if nonHost == nil {
                        nonHost = index
                    }
                    hostEnd = index
                case "@":
                    atSign = index
                    nonHost = nil
                default:
                    break
                }
                if hostEnd != nil {
                    break
                }
                index = rest.unicodeScalars.index(after: index)
            }
            let hostStart = atSign.map { rest.unicodeScalars.index(after: $0) } ?? rest.startIndex
            var host: String
            if let nonHost {
                host = String(rest[hostStart..<nonHost])
                rest = rest[nonHost...]
            } else {
                host = String(rest[hostStart...])
                rest = ""
            }

            // `/:[0-9]*$/` is the port.
            if let colon = host.unicodeScalars.lastIndex(of: ":"),
               host.unicodeScalars[host.unicodeScalars.index(after: colon)...].allSatisfy({ ("0"..."9").contains($0) }) {
                host = String(host.unicodeScalars[..<colon])
            }
            // A colon left in the host ends it; the rest goes to the path
            // (Node's `getHostname`).
            if let colon = host.unicodeScalars.firstIndex(of: ":") {
                rest = Substring("/" + String(host.unicodeScalars[colon...]) + rest)
                host = String(host.unicodeScalars[..<colon])
            }
            hostname = JSCompat.toLowerCase(host)
        }

        // The hash goes first, then the query.
        var questionIndex: String.Index?
        var hashIndex: String.Index?
        var index = rest.startIndex
        while index < rest.endIndex {
            let scalar = rest.unicodeScalars[index]
            if scalar == "#" {
                hashIndex = index
                break
            }
            if scalar == "?", questionIndex == nil {
                questionIndex = index
            }
            index = rest.unicodeScalars.index(after: index)
        }
        if let questionIndex {
            query = Self.parseQueryString(rest[rest.unicodeScalars.index(after: questionIndex)..<(hashIndex ?? rest.endIndex)])
        }
        let firstIndex = questionIndex ?? hashIndex
        if let firstIndex {
            if firstIndex > rest.startIndex {
                pathname = String(rest[..<firstIndex])
            }
        } else if !rest.isEmpty {
            pathname = String(rest)
        }
    }

    private static func isProtocolCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "+", "-": true
        default: false
        }
    }

    /// Node's `slashedProtocol`, compared with the protocol as written: these
    /// have a host only after `//`.
    private static let slashedProtocols: Set<String> = [
        "http:", "https:", "ftp:", "gopher:", "file:", "ws:", "wss:",
    ]

    /// Node's `querystring.parse`: `&`-separated pairs split at the first
    /// `=`, with `+` as a space and percent escapes decoded (a malformed
    /// escape is kept as it is). A repeated key keeps every value.
    static func parseQueryString(_ query: Substring) -> [String: [String]] {
        var result: [String: [String]] = [:]
        guard !query.isEmpty else {
            return result
        }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let key: Substring
            let value: Substring
            if let equals = pair.firstIndex(of: "=") {
                key = pair[..<equals]
                value = pair[pair.index(after: equals)...]
            } else {
                key = pair
                value = ""
            }
            result[unescape(key), default: []].append(unescape(value))
        }
        return result
    }

    /// `querystring.unescape` after replacing `+`: `decodeURIComponent`,
    /// or, when that fails, every valid escape decoded and the rest kept.
    private static func unescape(_ string: Substring) -> String {
        let spaced = string.replacing("+", with: " ")
        if let decoded = spaced.removingPercentEncoding {
            return decoded
        }
        var bytes: [UInt8] = []
        let utf8 = Array(spaced.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
               let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

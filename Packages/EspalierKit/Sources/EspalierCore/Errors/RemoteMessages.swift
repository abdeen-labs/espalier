// Ported from desktop/app/src/ui/dispatcher/error-handlers.ts
//
// Their input is git's output, so the patterns keep JavaScript's semantics
// (JSCompat): `.` never matches a line terminator, `\s` is JavaScript's
// whitespace, and `^` with the `m` flag matches after `\n`, `\r`, U+2028, and
// U+2029 only.

import EspalierSupport
import Foundation
import GitHubKit

/// Represents the location of a detected secret detected on push
public struct SecretLocation: Sendable, Hashable {
    /// The SHA of the commit where the secret was detected.
    public let commitSha: String
    /// The file path where the secret is located.
    public let path: String
    /// The line number in the file where the secret is found.
    public let lineNumber: Int

    public init(commitSha: String, path: String, lineNumber: Int) {
        self.commitSha = commitSha
        self.path = path
        self.lineNumber = lineNumber
    }
}

/// Represents secret detected by GitHub's Secret Scanning feature on push.
public struct SecretScanResult: Sendable, Hashable {
    /// The id used in the bypassURL to unique identify this secret
    public let id: String
    /// The name of the secret - e.g "GitHub Access Token"
    public let description: String
    /// The location of the secret, given as a commitSha, file path, and line number
    public let locations: [SecretLocation]
    /// The URL to use to get to GitHub.com's dialog for bypassing blocking the push of the secret
    public let bypassURL: String
    /// The user cannot bypass themselves, but can request a bypass
    public let requiresApproval: Bool

    public init(id: String, description: String, locations: [SecretLocation], bypassURL: String, requiresApproval: Bool) {
        self.id = id
        self.description = description
        self.locations = locations
        self.bypassURL = bypassURL
        self.requiresApproval = requiresApproval
    }
}

extension SecretScanResult {
    /// GitHub's bypass page for the secret, to open for a repository on
    /// `endpoint` (its GitHub API endpoint; nil when the repository isn't
    /// known to be on GitHub): `bypassURL` when it's an `https` address on
    /// github.com or on `endpoint`'s server, else nil. The address comes
    /// from the remote's output, which any server can write.
    public func bypassPage(onGitHubAt endpoint: String?) -> URL? {
        guard let url = URL(string: bypassURL),
              url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false)?.lowercased()
        else {
            return nil
        }
        var gitHubHosts: Set<String> = ["github.com"]
        if let endpoint, let serverHost = URL(string: getHTMLURL(endpoint))?.host(percentEncoded: false) {
            gitHubHosts.insert(serverHost.lowercased())
        }
        return gitHubHosts.contains(host) ? url : nil
    }
}

/// JavaScript's `^` with the `m` flag: the start of the input, or right after
/// a JavaScript line terminator.
private let jsLineStart = #"(?:^|(?<=[\n\r\u2028\u2029]))"#

/// Extract lines from Git's stderr output starting with the prefix
/// `remote: `. Useful to extract server-specific error messages from network
/// operations (fetch, push, pull, etc).
func getRemoteMessage(_ stderr: String) -> String {
    let needle = "remote: "

    // `stderr.split(/\r?\n/)`
    let lines = JSCompat.split(stderr, "\n").map { line in
        JSCompat.endsWith(line, "\r") ? String(line.dropLast()) : line
    }
    return lines
        .filter { JSCompat.startsWith($0, needle) }
        .map { JSCompat.dropFirst($0, needle.unicodeScalars.count) }
        .joined(separator: "\n")
}

/// `/^ ! \[remote rejected\] .*? -> .*? \(refusing to allow an OAuth App to
/// create or update workflow `(.*?)` without `workflow` scope\)/m`
let rejectedPathRe = JSCompat.regex(
    jsLineStart
        + #" ! \[remote rejected\] "# + JSCompat.dot + "*? -> " + JSCompat.dot
        + #"*? \(refusing to allow an OAuth App to create or update workflow `("# + JSCompat.dot
        + #"*?)` without `workflow` scope\)"#
)

/// The workflow file a push was rejected for because the token lacks the
/// `workflow` scope, from the error's message.
func getRejectedWorkflowPath(_ message: String) -> String? {
    JSCompat.match(message, rejectedPathRe)?[1]
}

/// `/'([^']+)' organization has enabled or enforced SAML SSO.*?you must
/// re-authorize/s`
let samlReauthErrorMessageRe = JSCompat.regex(
    #"'([^']+)' organization has enabled or enforced SAML SSO[\s\S]*?you must re-authorize"#
)

/// The organization that requires signing in again for SAML single sign-on,
/// from the remote's message (`getRemoteMessage`).
func getSAMLReauthOrganization(_ remoteMessage: String) -> String? {
    JSCompat.match(remoteMessage, samlReauthErrorMessageRe)?[1]
}

/// GitHub's refusal when an organization's OAuth App access restrictions
/// don't allow the app the credentials came from. GitHub's git server says,
/// as its API does: "Although you appear to have the correct authorization
/// credentials, the `octo-org' organization has enabled OAuth App access
/// restrictions, meaning that data access to third-parties is limited.";
/// git wraps it over `remote:` lines, and the quotes around the name vary.
let oauthAppAccessRestrictedRe = JSCompat.regex(
    #"[`'"]?([^`'"\s]+)[`'"]?"# + JSCompat.whitespace + "+organization" + JSCompat.whitespace
        + "+has" + JSCompat.whitespace + "+enabled" + JSCompat.whitespace + "+(?i:OAuth)" + JSCompat.whitespace
        + "+(?i:App)" + JSCompat.whitespace + "+access" + JSCompat.whitespace + "+restrictions"
)

/// The organization whose OAuth App access restrictions refused the
/// operation, from the remote's message (`getRemoteMessage`).
func getOAuthAppRestrictedOrganization(_ remoteMessage: String) -> String? {
    JSCompat.match(remoteMessage, oauthAppAccessRestrictedRe)?[1]
}

/// `/—— (?<description>.*?) —+[\s\S]*?locations:(?<locationsGroup>(?:\s+-
/// commit: [a-f0-9]{40}\s+path: [\s\S]*?)+).*?(?<bypassURL>https[\s\S]*?) /g`
private let secretsRegex = JSCompat.regex(
    #"\u2014\u2014 (?<description>"# + JSCompat.dot + #"*?) \u2014+[\s\S]*?locations:(?<locationsGroup>(?:"#
        + JSCompat.whitespace + "+- commit: [a-f0-9]{40}" + JSCompat.whitespace + #"+path: [\s\S]*?)+)"#
        + JSCompat.dot + #"*?(?<bypassURL>https[\s\S]*?) "#
)

/// `/- commit: (?<commitSha>[a-f0-9]{40})\s+path: (?<path>.*?):(?<lineNumber>\d+)/g`
private let locationsRegex = JSCompat.regex(
    "- commit: (?<commitSha>[a-f0-9]{40})" + JSCompat.whitespace + "+path: (?<path>" + JSCompat.dot
        + "*?):(?<lineNumber>" + JSCompat.digit + "+)"
)

/// Extracts secret scanning results from the provided `remoteMessage` string
/// from the git error provided when GitHub Secret Scanning detects a secret
/// on push.
///
/// This function parses the output of a secret scanning tool to identify
/// secrets, their descriptions, locations in the codebase, and bypass URLs.
func extractSecretScanningResults(_ remoteMessage: String) -> [SecretScanResult] {
    let text = remoteMessage as NSString
    let matches = secretsRegex.matches(in: remoteMessage, range: NSRange(location: 0, length: text.length))

    return matches.compactMap { match in
        guard let bypassURL = group(match, "bypassURL", in: text),
              let description = group(match, "description", in: text),
              let locationsGroup = group(match, "locationsGroup", in: text)
        else {
            return nil
        }

        let locationsText = locationsGroup as NSString
        let locations = locationsRegex
            .matches(in: locationsGroup, range: NSRange(location: 0, length: locationsText.length))
            .compactMap { location -> SecretLocation? in
                guard let commitSha = group(location, "commitSha", in: locationsText),
                      let path = group(location, "path", in: locationsText),
                      let lineNumber = group(location, "lineNumber", in: locationsText)
                else {
                    return nil
                }
                return SecretLocation(commitSha: commitSha, path: path, lineNumber: JSCompat.parseInt(lineNumber) ?? 0)
            }

        return SecretScanResult(
            // `bypassURL.split('/').pop() || ''`
            id: JSCompat.split(bypassURL, "/").last ?? "",
            description: description,
            locations: locations,
            bypassURL: bypassURL,
            requiresApproval: JSCompat.includes(text.substring(with: match.range), "request an exemption")
        )
    }
}

/// The text of the named group, or nil when it didn't take part in the match.
private func group(_ match: NSTextCheckingResult, _ name: String, in text: NSString) -> String? {
    let range = match.range(withName: name)
    return range.location == NSNotFound ? nil : text.substring(with: range)
}

/// `/(;\sthis\sexceeds\sGitHub's\sfile\ssize\slimit\sof\s100.00\sMB)/gm`
private let exceedsEndRegex = JSCompat.regex(
    ";" + JSCompat.whitespace + "this" + JSCompat.whitespace + "exceeds" + JSCompat.whitespace + "GitHub's"
        + JSCompat.whitespace + "file" + JSCompat.whitespace + "size" + JSCompat.whitespace + "limit"
        + JSCompat.whitespace + "of" + JSCompat.whitespace + "100" + JSCompat.dot + "00" + JSCompat.whitespace + "MB"
)

/// `/(^remote:\serror:\sFile\s)/gm`
private let exceedsBeginRegex = JSCompat.regex(
    jsLineStart + "remote:" + JSCompat.whitespace + "error:" + JSCompat.whitespace + "File" + JSCompat.whitespace
)

/// Looks for the phrases "remote: error File " and " is (file size I.E.
/// 106.5 MB); this exceeds GitHub's file size limit of 100.00 MB" inside of a
/// string containing errors and return an array of all the filenames and
/// their sizes located between these two strings.
///
/// example return [ "LargeFile.exe (150.00 MB)", "AlsoTooLargeOfAFile.txt (1.00 GB)" ]
///
/// The last `is ` (the one before the size) becomes `(`, so a file name
/// containing `is ` (`this is big.bin is 150.00 MB`) stays whole.
func getFileFromExceedsError(_ error: String) -> [String] {
    let text = error as NSString
    let range = NSRange(location: 0, length: text.length)
    let beginMatches = exceedsBeginRegex.matches(in: error, range: range)
    let endMatches = exceedsEndRegex.matches(in: error, range: range)

    // Something went wrong and we didn't find the same amount of endings as we did beginnings
    // Just return an empty array as the output we'd give would look weird anyway
    if beginMatches.count != endMatches.count {
        return []
    }

    return zip(beginMatches, endMatches).map { beginMatch, endMatch in
        let from = beginMatch.range.location + beginMatch.range.length
        let to = endMatch.range.location
        // `error.slice(from, to)` is empty when the end comes first.
        var file = to > from ? text.substring(with: NSRange(location: from, length: to - from)) : ""
        if let separator = file.range(of: "is ", options: [.literal, .backwards]) {
            file.replaceSubrange(separator, with: "(")
        }
        return file + ")"
    }
}

// Ported from desktop/app/src/lib/trampoline/url-without-credentials.ts

import EspalierSupport
import Foundation

public func urlWithoutCredentials(_ remoteUrl: String) throws(JSURLError) -> String {
    urlWithoutCredentials(try JSURL(remoteUrl))
}

public func urlWithoutCredentials(_ remoteUrl: JSURL) -> String {
    var url = remoteUrl
    url.username = ""
    url.password = ""
    return url.href
}

/// A URL's scheme and `://` (group 1), then its user information: up to
/// the last `@` before the end of the host part, which is the first `/`,
/// `?`, or `#` (as git's `credential_from_url` ends it) or whitespace.
private let urlUserInformation = try! NSRegularExpression(
    pattern: #"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/?#]*@"#
)

/// `text` with the user information taken out of every URL in it, as
/// `urlWithoutCredentials` takes it out of one: the user name and the
/// password, whatever the scheme (`https://user:token@host/repo.git` and
/// `ssh://git@host/repo.git` become `https://host/repo.git` and
/// `ssh://host/repo.git`). For logs.
///
/// Unlike `urlWithoutCredentials`, it finds URLs inside other text (git's
/// output, a `-c name=<url>` argument), cleans one that doesn't parse, and
/// keeps the rest as written. Scp-like addresses (`git@host:path`) aren't
/// URLs and stay as they are: they name a user, never a password.
public func withoutURLCredentials(_ text: String) -> String {
    guard text.utf8.contains(UInt8(ascii: "@")) else {
        return text
    }
    return urlUserInformation.stringByReplacingMatches(
        in: text,
        range: NSRange(text.startIndex..., in: text),
        withTemplate: "$1"
    )
}

// `withoutURLCredentials` takes the user name and password out of URLs in
// git's arguments and output, as they go into the log.

import GitKit
import Testing
import TestSupport

@Suite("withoutURLCredentials")
struct WithoutURLCredentialsTests {
    @Test("takes credentials out of URLs and leaves everything else", arguments: [
        NamedCase("a user and a password", (text: "https://user:pass@example.com/x.git", expected: "https://example.com/x.git")),
        NamedCase("a user only", (text: "https://user@example.com/x.git", expected: "https://example.com/x.git")),
        NamedCase("http, with a port", (text: "http://user:pass@example.com:8080/x", expected: "http://example.com:8080/x")),
        NamedCase("percent-encoded credentials", (text: "https://us%40er:p%3Ass%2Fword@example.com/x", expected: "https://example.com/x")),
        // Everything up to the host part's last `@` goes, so a password with
        // an `@` leaves nothing of itself.
        NamedCase("an `@` in the password", (text: "https://user:p@ss@example.com/x", expected: "https://example.com/x")),
        NamedCase("no path", (text: "https://user:token@example.com", expected: "https://example.com")),
        NamedCase("a query and a fragment", (text: "https://user:token@example.com?a=b#c", expected: "https://example.com?a=b#c")),
        NamedCase("an uppercase scheme", (text: "HTTPS://user:token@Example.com/x", expected: "HTTPS://Example.com/x")),
        // As `urlWithoutCredentials` does, the user name goes for every scheme.
        NamedCase("an ssh URL's user", (text: "ssh://git@example.com/x.git", expected: "ssh://example.com/x.git")),
        NamedCase("a git+ssh URL's user", (text: "git+ssh://git@example.com:22/x.git", expected: "git+ssh://example.com:22/x.git")),
        NamedCase("an scp-like address", (text: "git@example.com:owner/x.git", expected: "git@example.com:owner/x.git")),
        NamedCase("a URL without credentials", (text: "https://example.com/x.git", expected: "https://example.com/x.git")),
        NamedCase("an `@` in the path", (text: "https://example.com/owner/x@v1", expected: "https://example.com/owner/x@v1")),
        NamedCase("an `@` in the query", (text: "https://example.com/x?email=joe@example.com", expected: "https://example.com/x?email=joe@example.com")),
        NamedCase("an option", (text: "--progress", expected: "--progress")),
        NamedCase("a refspec", (text: "refs/heads/main:refs/remotes/origin/main", expected: "refs/heads/main:refs/remotes/origin/main")),
        NamedCase("a reflog entry", (text: "HEAD@{1}", expected: "HEAD@{1}")),
        NamedCase("an email address", (text: "user.email=joe@example.com", expected: "user.email=joe@example.com")),
        NamedCase("an empty argument", (text: "", expected: "")),
        NamedCase("a URL in a configuration argument", (text: "remote.origin.url=https://user:token@example.com/x.git", expected: "remote.origin.url=https://example.com/x.git")),
        NamedCase(
            "a URL in git's output",
            (text: "fatal: unable to access 'https://user:token@example.com/x.git/': The requested URL returned error: 403\n",
             expected: "fatal: unable to access 'https://example.com/x.git/': The requested URL returned error: 403\n")
        ),
        NamedCase("a URL in quotes, without a path", (text: "'https://user:token@example.com': error", expected: "'https://example.com': error")),
        NamedCase("a URL at the end of a line", (text: "https://user:token@example.com\nTo joe@example.com", expected: "https://example.com\nTo joe@example.com")),
        NamedCase(
            "two URLs",
            (text: "o\thttps://joe:one@example.com/x.git (fetch)\no\thttps://joe:two@example.com/x.git (push)\n",
             expected: "o\thttps://example.com/x.git (fetch)\no\thttps://example.com/x.git (push)\n")
        ),
        NamedCase("non-ASCII around a URL", (text: "é https://user:tökén@例え.jp/x 🌳", expected: "é https://例え.jp/x 🌳")),
    ])
    func strips(_ testCase: NamedCase<(text: String, expected: String)>) {
        #expect(withoutURLCredentials(testCase.value.text) == testCase.value.expected)
    }
}

// Ported from desktop/app/test/unit/parse-app-url-test.ts

@testable import EspalierCore
import Testing

@Suite("parseAppURL")
struct ParseAppURLTests {
    @Test("returns unknown by default")
    func unknownByDefault() {
        #expect(parseAppURL("").name == "unknown")
    }

    // "oauth returns right name": signing in uses the device flow, which has
    // no browser callback, so an oauth URL is unknown.
    @Test("returns unknown for oauth, which the device flow doesn't use")
    func oauth() {
        let result = parseAppURL("x-github-client://oauth?code=18142422&state=e4cd2dea-1567-46aa-8eb2-c7f56e943187")
        #expect(result == .unknown(url: "x-github-client://oauth?code=18142422&state=e4cd2dea-1567-46aa-8eb2-c7f56e943187"))
    }

    @Suite("openRepo via HTTPS")
    struct HTTPS {
        @Test("returns right name")
        func rightName() throws {
            let result = parseAppURL("github-mac://openRepo/https://github.com/desktop/desktop")
            #expect(result.name == "open-repository-from-url")
            guard case .openRepositoryFromURL(let openRepo) = result else {
                return
            }
            #expect(openRepo.url == "https://github.com/desktop/desktop")
        }

        @Test("returns unknown when no remote defined")
        func noRemote() {
            #expect(parseAppURL("github-mac://openRepo/").name == "unknown")
        }

        @Test("adds branch name if set")
        func branch() {
            let result = parseAppURL("github-mac://openRepo/https://github.com/desktop/desktop?branch=cancel-2fa-flow")
            #expect(result == .openRepositoryFromURL(OpenRepositoryFromURLAction(
                url: "https://github.com/desktop/desktop",
                branch: "cancel-2fa-flow"
            )))
        }

        @Test("adds pull request ID if found")
        func pullRequest() {
            let result = parseAppURL("github-mac://openRepo/https://github.com/octokit/octokit.net?branch=pr%2F1569&pr=1569")
            #expect(result == .openRepositoryFromURL(OpenRepositoryFromURLAction(
                url: "https://github.com/octokit/octokit.net",
                branch: "pr/1569",
                pr: "1569"
            )))
        }

        @Test("returns unknown for unexpected pull request input")
        func unexpectedPullRequest() {
            #expect(parseAppURL("github-mac://openRepo/https://github.com/octokit/octokit.net?branch=bar&pr=foo").name == "unknown")
        }

        @Test("returns unknown for invalid branch name")
        func invalidBranch() {
            // branch=<>
            #expect(parseAppURL("github-mac://openRepo/https://github.com/octokit/octokit.net?branch=%3C%3E").name == "unknown")
        }

        @Test("adds file path if found")
        func filePath() {
            let result = parseAppURL(
                "github-mac://openRepo/https://github.com/octokit/octokit.net?branch=master&filepath=Octokit.Reactive%2FOctokit.Reactive.csproj"
            )
            #expect(result == .openRepositoryFromURL(OpenRepositoryFromURLAction(
                url: "https://github.com/octokit/octokit.net",
                branch: "master",
                filepath: "Octokit.Reactive/Octokit.Reactive.csproj"
            )))
        }
    }

    @Suite("openRepo via SSH")
    struct SSH {
        @Test("returns right name")
        func rightName() {
            let result = parseAppURL("github-mac://openRepo/git@github.com/desktop/desktop")
            #expect(result == .openRepositoryFromURL(OpenRepositoryFromURLAction(url: "git@github.com/desktop/desktop")))
        }

        // Query parsing doesn't depend on the remote's form: the HTTPS suite
        // covers it.
    }

    /// A URL and its expected parse: nil for unknown.
    struct Recorded: Sendable, CustomTestStringConvertible {
        let url: String
        let expected: OpenRepositoryFromURLAction?

        var testDescription: String {
            url
        }

        static let all: [Recorded] = [
            Recorded(url: "espalier://OPENREPO/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "ESPALIER://openRepo/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "  espalier://openRepo/https://github.com/a/b  ", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "http://openRepo/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "espalier:openRepo/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "espalier://user@openRepo/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "espalier://openRepo:8080/https://github.com/a/b", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "espalier://somethingElse/https://github.com/a/b", expected: nil),
            Recorded(url: "espalier://openRepo", expected: nil),
            Recorded(url: "espalier:///https://github.com/a/b", expected: nil),
            Recorded(url: "espalier://openRepo//", expected: .init(url: "/")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b/?branch=main", expected: .init(url: "https://github.com/a/b/", branch: "main")),
            Recorded(
                url: "espalier://openRepo/git@github.com:desktop/desktop.git?branch=main",
                expected: .init(url: "git@github.com:desktop/desktop.git", branch: "main")
            ),
            // The query: the first of repeated keys, `+` as a space, escapes
            // decoded (malformed ones kept), the hash ending it.
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=a&branch=b", expected: .init(url: "https://github.com/a/b", branch: "a")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=feature+x", expected: nil),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=a%2Bb", expected: .init(url: "https://github.com/a/b", branch: "a+b")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=caf%C3%A9", expected: .init(url: "https://github.com/a/b", branch: "caf\u{E9}")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=%E0%A4%A", expected: .init(url: "https://github.com/a/b", branch: "\u{FFFD}%A")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?filepath=a%ZZb", expected: .init(url: "https://github.com/a/b", filepath: "a%ZZb")),
            Recorded(
                url: "espalier://openRepo/https://github.com/a/b?filepath=src%2Fmain.swift#L10",
                expected: .init(url: "https://github.com/a/b", filepath: "src/main.swift")
            ),
            Recorded(url: "espalier://openRepo/https://github.com/a/b#frag?branch=x", expected: .init(url: "https://github.com/a/b")),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?=x&branch", expected: .init(url: "https://github.com/a/b", branch: "")),
            // Branch names git refuses.
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=feature/", expected: nil),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=release.lock", expected: nil),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?branch=%40%7B", expected: nil),
            // Pull requests: digits, and a branch named pr/<digits> if any.
            Recorded(url: "espalier://openRepo/https://github.com/a/b?pr=12", expected: .init(url: "https://github.com/a/b", pr: "12")),
            Recorded(
                url: "espalier://openRepo/https://github.com/a/b?pr=12&branch=pr/12",
                expected: .init(url: "https://github.com/a/b", branch: "pr/12", pr: "12")
            ),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?pr=12&branch=feature", expected: nil),
            Recorded(url: "espalier://openRepo/https://github.com/a/b?pr=", expected: nil),
            // File paths pass through; opening one is checked later.
            Recorded(url: "espalier://openRepo/https://github.com/a/b?filepath=%2Fetc%2Fpasswd", expected: .init(url: "https://github.com/a/b", filepath: "/etc/passwd")),
        ]
    }

    @Test("parses as desktop's parser did", arguments: Recorded.all)
    func recorded(_ recorded: Recorded) {
        let result = parseAppURL(recorded.url)
        if let expected = recorded.expected {
            #expect(result == .openRepositoryFromURL(expected))
        } else {
            #expect(result == .unknown(url: recorded.url))
        }
    }

    @Test("a branch is checked without carrying state from a rejected one")
    func statelessBranchCheck() {
        // A global regex that kept its position after a rejection would reject
        // the next valid name, or pass an invalid one.
        #expect(parseAppURL("espalier://openRepo/https://github.com/a/b?branch=bad..name").name == "unknown")
        #expect(parseAppURL("espalier://openRepo/https://github.com/a/b?branch=good").name == "open-repository-from-url")
        #expect(parseAppURL("espalier://openRepo/https://github.com/a/b?branch=x..y").name == "unknown")
    }
}

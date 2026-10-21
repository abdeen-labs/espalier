// The stderr here is shaped as git prints GitHub's rejections: the push
// protection report as GitHub documents it, the SAML message the pattern
// expects, and the GH001 file size message.

@testable import EspalierCore
import Foundation
import Testing
import TestSupport

/// Lines a remote sent, as git prints them on stderr when stderr isn't a
/// terminal: each prefixed with `remote: `, and each line with text padded
/// with eight spaces, git's way of clearing what a progress line left.
private func remote(_ lines: [String]) -> String {
    lines.map { $0.isEmpty ? "remote: \n" : "remote: \($0)        \n" }.joined()
}

private func remote(_ lines: String...) -> String {
    remote(lines)
}

/// `count` em dashes, as GitHub draws its push protection headings.
private func dashes(_ count: Int) -> String {
    String(repeating: "\u{2014}", count: count)
}

private let firstSHA = "8728dbe67b7e6c2c3b2b0a1b6e5e9b8b6b1b9b0a"
private let secondSHA = "03d69e5d3c1f4e2b8a7d6c5b4a39281706f5e4d3"
private let unblockURL = "https://github.com/example-org/example-repo/security/secret-scanning/unblock-secret/2b4mZp3lFBlqWwSmW3bwcVJF1jJ"
private let secondUnblockURL = "https://github.com/example-org/example-repo/security/secret-scanning/unblock-secret/2b4mZpQ8nXkcZ0Qx1lyb2WF6tHr"

/// Bypass pages, the GitHub API endpoint of the repository they're for
/// (nil when it isn't known to be on GitHub), and whether they open.
private let bypassPageCases: [NamedCase<(url: String, endpoint: String?, opens: Bool)>] = [
    NamedCase("github.com, for a repository on github.com", (url: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: true)),
    NamedCase("github.com, for a repository not known to be on GitHub", (url: "https://github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: nil, opens: true)),
    NamedCase("github.com, in capitals", (url: "https://GitHub.COM/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: true)),
    NamedCase("the repository's Enterprise server", (url: "https://ghe.example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://ghe.example.com/api/v3", opens: true)),
    NamedCase("the repository's Enterprise server, on a port", (url: "https://ghe.example.com:8443/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://ghe.example.com:8443/api/v3", opens: true)),
    NamedCase("the repository's GHE.com server", (url: "https://octo.ghe.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.octo.ghe.com/", opens: true)),
    NamedCase("an Enterprise server, for a repository on github.com", (url: "https://ghe.example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("an Enterprise server, for a repository not known to be on GitHub", (url: "https://ghe.example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: nil, opens: false)),
    NamedCase("another Enterprise server", (url: "https://ghe.other.example/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://ghe.example.com/api/v3", opens: false)),
    NamedCase("another server", (url: "https://example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("a server named after github.com", (url: "https://github.com.example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("a subdomain of github.com", (url: "https://gist.github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("github.com as a user name", (url: "https://github.com@example.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("github.com after a fragment", (url: "https://example.com#@github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("http", (url: "http://github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("another scheme", (url: "httpsx://github.com/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
    NamedCase("no host", (url: "https:/octocat/hello/security/secret-scanning/unblock-secret/2abc", endpoint: "https://api.github.com", opens: false)),
]

private let pushProgress = """
    Enumerating objects: 5, done.
    Counting objects: 100% (5/5), done.
    Delta compression using up to 10 threads
    Compressing objects: 100% (3/3), done.
    Writing objects: 100% (3/3), 341 bytes | 341.00 KiB/s, done.
    Total 3 (delta 1), reused 0 (delta 0), pack-reused 0

    """

private let pushRejection = """
    To https://github.com/example-org/example-repo.git
     ! [remote rejected] main -> main (push declined due to repository rule violations)
    error: failed to push some refs to 'https://github.com/example-org/example-repo.git'

    """

/// One secret's block in a push protection report.
private func secretBlock(_ description: String, locations: [(sha: String, path: String)], prompt: String, url: String) -> [String] {
    ["      \(dashes(2)) \(description) \(dashes(22))", "       locations:"]
        + locations.flatMap { ["         - commit: \($0.sha)", "           path: \($0.path)"] }
        + ["    ", "       (?) \(prompt)", "       \(url)", "    ", ""]
}

/// The stderr of a push that push protection blocked.
private func pushProtectionStderr(_ secrets: [[String]]) -> String {
    let lines = [
        "Resolving deltas: 100% (1/1), completed with 1 local object.",
        "error: GH013: Repository rule violations found for refs/heads/main.",
        "",
        "- GITHUB PUSH PROTECTION",
        "  \(dashes(41))",
        "    Resolve the following violations before pushing again",
        "",
        "    - Push cannot contain secrets",
        "",
        "    ",
        "     (?) Learn how to resolve a blocked push",
        "     https://docs.github.com/code-security/secret-scanning/working-with-secret-scanning-and-push-protection/working-with-push-protection-from-the-command-line#resolving-a-blocked-push",
        "    ",
        "    ",
    ] + secrets.flatMap { $0 } + [""]
    return pushProgress + remote(lines) + pushRejection
}

private let allowPrompt = "To push, remove secret from commit(s) or follow this URL to allow the secret."

/// A push git reports refused for `line`.
private func workflowRejection(_ line: String) -> String {
    "To https://github.com/example-org/example-repo.git\n\(line)\nerror: failed to push some refs to 'https://github.com/example-org/example-repo.git'\n"
}

/// The stderr of a push GitHub refused for the files over its size limit,
/// one `error: File ...` line for each of `errors`.
private func fileSizeStderr(_ errors: String...) -> String {
    pushProgress
        + remote(
            "error: Trace: 6b3a0e3f1c7d8a9b2e4f5a6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e",
            "error: See https://gh.io/lfs for more information."
        )
        + remote(errors.map { "error: File " + $0 })
        + remote("error: GH001: Large files detected. You may want to try Git Large File Storage - https://git-lfs.github.com.")
        + """
        To https://github.com/example-org/example-repo.git
         ! [remote rejected] main -> main (pre-receive hook declined)
        error: failed to push some refs to 'https://github.com/example-org/example-repo.git'

        """
}

@Suite("Remote messages")
struct RemoteMessagesTests {
    @Suite("getRemoteMessage")
    struct RemoteMessage {
        @Test("returns the remote's lines without their prefix", arguments: [
            NamedCase(
                "keeps the remote's lines, without their prefix",
                (
                    stderr: pushProgress + remote("Resolving deltas: 100% (1/1)", "", "error: GH006: Protected branch update failed") + pushRejection,
                    expected: "Resolving deltas: 100% (1/1)        \n\nerror: GH006: Protected branch update failed        "
                )
            ),
            NamedCase("splits lines at CRLF too", (stderr: "remote: one\r\nremote: two\r\nfatal: three\r\n", expected: "one\ntwo")),
            NamedCase(
                "only counts lines that start with the prefix and its space",
                (stderr: "remote:\nremote: kept\n  remote: indented\nRemote: capital\nremote:tab\n", expected: "kept")
            ),
            NamedCase("only counts lines that start with the prefix and its space: none do", (stderr: "fatal: no remote lines\n", expected: "")),
            NamedCase(
                "keeps a carriage return inside a line, as progress lines have",
                (
                    stderr: "remote: Counting objects:  50% (1/2)\rremote: Counting objects: 100% (2/2), done.\n",
                    expected: "Counting objects:  50% (1/2)\rremote: Counting objects: 100% (2/2), done."
                )
            ),
        ])
        func remoteMessage(_ testCase: NamedCase<(stderr: String, expected: String)>) {
            #expect(getRemoteMessage(testCase.value.stderr) == testCase.value.expected)
        }
    }

    @Suite("rejected workflow")
    struct RejectedWorkflow {
        @Test("finds the workflow a push was refused for without the workflow scope", arguments: [
            NamedCase(
                "finds the workflow a push was refused for without the workflow scope",
                (
                    stderr: workflowRejection(
                        " ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)"
                    ),
                    expected: ".github/workflows/ci.yml"
                )
            ),
            NamedCase(
                "finds it for any branch, and takes the first refused workflow",
                (
                    stderr: """
                        To https://github.com/example-org/example-repo.git
                         ! [remote rejected] feature/ci -> feature/ci (refusing to allow an OAuth App to create or update workflow `.github/workflows/build and test.yml` without `workflow` scope)
                         ! [remote rejected] v2 -> v2 (refusing to allow an OAuth App to create or update workflow `.github/workflows/release.yml` without `workflow` scope)

                        """,
                    expected: ".github/workflows/build and test.yml"
                )
            ),
        ])
        func workflowPath(_ testCase: NamedCase<(stderr: String, expected: String)>) {
            #expect(getRejectedWorkflowPath(testCase.value.stderr) == testCase.value.expected)
        }

        @Test("needs the rejection at the start of a line, as JavaScript's multiline ^ finds it")
        func lineStarts() {
            let line = " ! [remote rejected] main -> main (refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)"
            #expect(getRejectedWorkflowPath(line) == ".github/workflows/ci.yml")
            #expect(getRejectedWorkflowPath("error:" + line) == nil)
            #expect(getRejectedWorkflowPath("progress\r" + line) == ".github/workflows/ci.yml")
            #expect(getRejectedWorkflowPath("before\u{2028}" + line) == ".github/workflows/ci.yml")
            #expect(getRejectedWorkflowPath("before\u{2029}" + line) == ".github/workflows/ci.yml")
            #expect(getRejectedWorkflowPath("before\u{85}" + line) == nil)
        }

        @Test("matches nothing for other rejections, or one split across lines")
        func otherRejections() {
            #expect(getRejectedWorkflowPath(workflowRejection(" ! [remote rejected] main -> main (pre-receive hook declined)")) == nil)
            #expect(getRejectedWorkflowPath(workflowRejection(" ! [rejected]        main -> main (non-fast-forward)")) == nil)
            #expect(
                getRejectedWorkflowPath(
                    " ! [remote rejected] main -> main\n(refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)"
                ) == nil
            )
        }
    }

    @Suite("SAML reauthorization")
    struct SAMLReauthorization {
        @Test("finds the organization that requires signing in again")
        func organization() {
            let stderr = remote(
                "The 'example-org' organization has enabled or enforced SAML SSO. To access",
                "this repository, you must re-authorize the OAuth Application 'Espalier'."
            ) + "fatal: unable to access 'https://github.com/example-org/example-repo.git/': The requested URL returned error: 403\n"
            #expect(getSAMLReauthOrganization(getRemoteMessage(stderr)) == "example-org")
        }

        @Test("finds it on one line too")
        func oneLine() {
            let message = "The 'Example Org, Inc' organization has enabled or enforced SAML SSO. To access this repository, you must re-authorize the OAuth Application 'Espalier'."
            #expect(getSAMLReauthOrganization(message) == "Example Org, Inc")
        }

        @Test("matches nothing when the message asks for something else, or names no organization")
        func otherMessages() {
            let token = remote(
                "The 'example-org' organization has enabled or enforced SAML SSO.",
                "To access this repository, you must use the HTTPS remote with a personal access token or SSH with an SSH key and passphrase that has been authorized for this organization."
            )
            #expect(getSAMLReauthOrganization(getRemoteMessage(token)) == nil)

            let unnamed = remote(
                "The organization has enabled or enforced SAML SSO.",
                "To access this repository, you must re-authorize the OAuth Application 'Espalier'."
            )
            #expect(getSAMLReauthOrganization(getRemoteMessage(unnamed)) == nil)

            // Only the remote's lines count.
            let local = "fatal: The 'example-org' organization has enabled or enforced SAML SSO. To access this repository, you must re-authorize the OAuth Application 'Espalier'.\n"
            #expect(getSAMLReauthOrganization(getRemoteMessage(local)) == nil)
        }
    }

    @Suite("secret scanning push protection")
    struct PushProtection {
        @Test("parses a secret, its locations, and its bypass URL")
        func oneSecret() {
            let stderr = pushProtectionStderr([
                secretBlock(
                    "GitHub Personal Access Token",
                    locations: [(firstSHA, "README.md:4"), (secondSHA, "config/settings.yml:12")],
                    prompt: allowPrompt,
                    url: unblockURL
                ),
            ])

            #expect(
                extractSecretScanningResults(getRemoteMessage(stderr)) == [
                    SecretScanResult(
                        id: "2b4mZp3lFBlqWwSmW3bwcVJF1jJ",
                        description: "GitHub Personal Access Token",
                        locations: [
                            SecretLocation(commitSha: firstSHA, path: "README.md", lineNumber: 4),
                            SecretLocation(commitSha: secondSHA, path: "config/settings.yml", lineNumber: 12),
                        ],
                        bypassURL: unblockURL,
                        requiresApproval: false
                    ),
                ]
            )
        }

        @Test("parses each secret on its own")
        func twoSecrets() {
            let stderr = pushProtectionStderr([
                secretBlock("GitHub Personal Access Token", locations: [(firstSHA, "README.md:4")], prompt: allowPrompt, url: unblockURL),
                secretBlock("OpenAI API Key", locations: [(secondSHA, ".env:8")], prompt: allowPrompt, url: secondUnblockURL),
            ])

            let results = extractSecretScanningResults(getRemoteMessage(stderr))
            #expect(results.map(\.description) == ["GitHub Personal Access Token", "OpenAI API Key"])
            #expect(results.map(\.id) == ["2b4mZp3lFBlqWwSmW3bwcVJF1jJ", "2b4mZpQ8nXkcZ0Qx1lyb2WF6tHr"])
            #expect(results.map(\.bypassURL) == [unblockURL, secondUnblockURL])
            #expect(results.map(\.locations) == [
                [SecretLocation(commitSha: firstSHA, path: "README.md", lineNumber: 4)],
                [SecretLocation(commitSha: secondSHA, path: ".env", lineNumber: 8)],
            ])
        }

        @Test("marks a secret whose bypass needs approval")
        func requiresApproval() {
            let stderr = pushProtectionStderr([
                secretBlock(
                    "Slack API Token",
                    locations: [(firstSHA, "deploy/notify.sh:3")],
                    prompt: "To push, remove secret from commit(s) or follow this URL to request an exemption.",
                    url: unblockURL
                ),
                secretBlock("OpenAI API Key", locations: [(secondSHA, ".env:8")], prompt: allowPrompt, url: secondUnblockURL),
            ])

            #expect(extractSecretScanningResults(getRemoteMessage(stderr)).map(\.requiresApproval) == [true, false])
        }

        @Test("finds nothing in other rejections, or without a bypass URL")
        func noSecrets() {
            let protectedBranch = remote(
                "error: GH006: Protected branch update failed for refs/heads/main.",
                "error: Changes must be made through a pull request."
            )
            #expect(extractSecretScanningResults(getRemoteMessage(protectedBranch)).isEmpty)
            #expect(extractSecretScanningResults("").isEmpty)

            let withoutURL = pushProtectionStderr([
                ["      \(dashes(2)) GitHub Personal Access Token \(dashes(22))", "       locations:", "         - commit: \(firstSHA)", "           path: README.md:4"],
            ])
            #expect(extractSecretScanningResults(getRemoteMessage(withoutURL)).isEmpty)
        }

        @Test("opens a bypass page only on github.com or the repository's GitHub server", arguments: bypassPageCases)
        func bypassPage(_ testCase: NamedCase<(url: String, endpoint: String?, opens: Bool)>) {
            let (url, endpoint, opens) = testCase.value
            let secret = SecretScanResult(id: "2abc", description: "GitHub Personal Access Token", locations: [], bypassURL: url, requiresApproval: true)
            #expect(secret.bypassPage(onGitHubAt: endpoint) == (opens ? URL(string: url) : nil))
        }
    }

    @Suite("file size limit")
    struct FileSizeLimit {
        @Test("names each file over the limit, with its size, in order", arguments: [
            NamedCase(
                "names each file over the limit, in order",
                (
                    stderr: fileSizeStderr(
                        "LargeFile.exe is 150.00 MB; this exceeds GitHub's file size limit of 100.00 MB",
                        "Assets/Movies/Also Too Large.mov is 1024.00 MB; this exceeds GitHub's file size limit of 100.00 MB"
                    ),
                    expected: ["LargeFile.exe (150.00 MB)", "Assets/Movies/Also Too Large.mov (1024.00 MB)"]
                )
            ),
            // Replacing the first "is " with "(" would mangle a name that
            // contains "is ".
            NamedCase(
                "keeps file names that contain 'is ' whole (desktop replaced the first one)",
                (
                    stderr: fileSizeStderr(
                        "this is big.bin is 150.00 MB; this exceeds GitHub's file size limit of 100.00 MB",
                        "Thesis draft.pdf is 120.00 MB; this exceeds GitHub's file size limit of 100.00 MB"
                    ),
                    expected: ["this is big.bin (150.00 MB)", "Thesis draft.pdf (120.00 MB)"]
                )
            ),
            NamedCase(
                "finds lines after CRLF",
                (
                    stderr: "remote: error: GH001: Large files detected.\r\nremote: error: File big.bin is 150.00 MB; this exceeds GitHub's file size limit of 100.00 MB\r\n",
                    expected: ["big.bin (150.00 MB)"]
                )
            ),
        ])
        func files(_ testCase: NamedCase<(stderr: String, expected: [String])>) {
            #expect(getFileFromExceedsError(testCase.value.stderr) == testCase.value.expected)
        }

        @Test("names nothing unless every file line has its ending")
        func mismatched() {
            // An older message without the size's decimals.
            let older = fileSizeStderr("giant_file is 123.00 MB; this exceeds GitHub's file size limit of 100 MB")
            #expect(getFileFromExceedsError(older) == [])

            // A file line that doesn't start a line.
            let indented = "  remote: error: File big.bin is 150.00 MB; this exceeds GitHub's file size limit of 100.00 MB\n"
            #expect(getFileFromExceedsError(indented) == [])

            #expect(getFileFromExceedsError("") == [])
            #expect(getFileFromExceedsError(remote("error: GH001: Large files detected.")) == [])
        }
    }
}

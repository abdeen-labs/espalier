import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Trampoline git environment")
struct TrampolineGitEnvironmentTests {
    @Suite("GitConfigParameters")
    struct ConfigParameters {
        @Test("quotes like git's sq_quote_buf")
        func quote() {
            #expect(GitConfigParameters.quote("a b") == "'a b'")
            #expect(GitConfigParameters.quote("it's") == "'it'\\''s'")
            #expect(GitConfigParameters.quote("wow!") == "'wow'\\!''")
            #expect(GitConfigParameters.quote("") == "''")
            #expect(GitConfigParameters.parameter("core.hooksPath", "/tmp/x") == "'core.hooksPath=/tmp/x'")
            #expect(GitConfigParameters.appending(["'a=1'", "'b=2'"], to: "") == "'a=1' 'b=2'")
            #expect(GitConfigParameters.appending(["'b=2'"], to: "'a=1'") == "'a=1' 'b=2'")
        }

        /// Asks git for every value of `key` with `GIT_CONFIG_PARAMETERS`
        /// set to `parameters`.
        func gitConfigValues(_ key: String, _ parameters: String) async throws -> [String] {
            let directory = try createTempDirectory()
            let result = try await Dugite.exec(
                ["config", "--null", "--get-all", key],
                directory,
                options: Dugite.ExecutionOptions(env: ["GIT_CONFIG_PARAMETERS": parameters])
            )
            try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
            return String(decoding: result.stdout, as: UTF8.self)
                .split(separator: "\0", omittingEmptySubsequences: false)
                .dropLast()
                .map(String.init)
        }

        @Test("survives git's parsing, whatever the value holds")
        func gitParsesQuotedValues() async throws {
            let values = ["plain", "with space", "it's", "a'b'c", "bang!", "'!'", "$HOME `x` \"q\" \\", "tab\tand\nnewline", "é\u{301}'\u{301}"]
            let parameters = GitConfigParameters.appending(values.map { GitConfigParameters.parameter("espalier.value", $0) }, to: "")
            #expect(try await gitConfigValues("espalier.value", parameters) == values)
        }

        @Test("makes the helper git's only credential helper, after existing parameters")
        func credentialHelper() async throws {
            let helper = "/Applications/My Apps/it's \"Espalier\"!.app/Contents/MacOS/espalier-askpass"
            let parameters = trampolineGitConfigParameters(
                existing: GitConfigParameters.parameter("core.hooksPath", "/tmp/hooks dir"),
                helperPath: helper
            )

            #expect(try await gitConfigValues("credential.helper", parameters) == ["", credentialHelperConfigValue(helperPath: helper)])
            #expect(try await gitConfigValues("core.hooksPath", parameters) == ["/tmp/hooks dir"])
            #expect(credentialHelperConfigValue(helperPath: helper) == #"!'/Applications/My Apps/it'\''s "Espalier"!.app/Contents/MacOS/espalier-askpass' --credential-helper"#)
        }

        @Test("runs the credential helper through the shell with its path intact")
        func credentialHelperRuns() async throws {
            let directory = POSIXPath.join(try createTempDirectory(), "it's a $dir `x` \"q\"!")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            let helper = POSIXPath.join(directory, "fake helper")
            try Data("#!/bin/sh\n[ \"$1\" = --credential-helper ] && [ \"$2\" = get ] && printf 'username=joe\\npassword=from-%s\\n' \"$(basename \"$0\")\"\n".utf8)
                .write(to: URL(filePath: helper))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)

            let result = try await Dugite.exec(
                ["credential", "fill"],
                try createTempDirectory(),
                options: Dugite.ExecutionOptions(
                    env: [
                        "GIT_CONFIG_PARAMETERS": trampolineGitConfigParameters(existing: "", helperPath: helper),
                        "GIT_TERMINAL_PROMPT": "0",
                    ],
                    stdin: Data("protocol=https\nhost=example.com\n".utf8)
                )
            )

            #expect(String(decoding: result.stdout, as: UTF8.self) == "protocol=https\nhost=example.com\nusername=joe\npassword=from-fake helper\n")
        }
    }

    @Suite("getCredentialUrl")
    struct CredentialURL {
        @Test("builds the URL from the credential's parts")
        func parts() throws {
            #expect(try getCredentialUrl(parseCredential("protocol=https\nhost=github.com\n")).href == "https://github.com/")
            #expect(try getCredentialUrl(parseCredential("protocol=http\nhost=127.0.0.1:8080\n")).href == "http://127.0.0.1:8080/")
            #expect(try getCredentialUrl(parseCredential("protocol=https\nhost=example.com\nusername=me@corp\npath=owner/my repo.git\n")).href
                == "https://me%40corp@example.com/owner/my%20repo.git")
            #expect(try getCredentialUrl(parseCredential("protocol=HTTPS\nhost=Example.COM:443\n")).href == "https://example.com/")
        }

        @Test("prefers the url attribute")
        func urlAttribute() throws {
            #expect(try getCredentialUrl(parseCredential("url=https://example.com/a\nprotocol=http\nhost=other\n")).href == "https://example.com/a")
        }

        @Test("throws for what isn't a URL")
        func invalid() {
            #expect(throws: JSURLError.self) {
                try getCredentialUrl(parseCredential("host=example.com\n"))
            }
        }

        @Test("removes credentials from a URL")
        func withoutCredentials() throws {
            #expect(try urlWithoutCredentials("https://joe:secret@example.com/repo.git") == "https://example.com/repo.git")
            #expect(try urlWithoutCredentials("https://joe@example.com") == "https://example.com/")
            #expect(try urlWithoutCredentials("http://example.com:8080/") == "http://example.com:8080/")
        }
    }

    @Test("names the git version, the app, and the platform in the user agent")
    func userAgent() async throws {
        TestEnvironment.bootstrap()
        let agent = await gitUserAgent(appVersion: "1.2.3")
        #if arch(arm64)
        #expect(agent == "git/\(gitVersion) (Espalier/1.2.3; darwin arm64)")
        #else
        #expect(agent == "git/\(gitVersion) (Espalier/1.2.3; darwin x64)")
        #endif
    }

    @Suite("userCancelledAuthenticationError")
    struct CancelledAuthentication {
        func gitError(_ output: String, gitError: DugiteError? = nil) -> GitError {
            GitError(
                result: GitResult(stdoutData: Data(), stderrData: Data(output.utf8), exitCode: 128, gitError: gitError, gitErrorDescription: nil, path: "/"),
                args: ["fetch", "origin"],
                terminalOutput: output
            )
        }

        @Test("rewrites git's terminal prompts error as an authentication failure")
        func rewrites() throws {
            let original = gitError("fatal: could not read Username for 'https://example.com': terminal prompts disabled\n")
            let rewritten = try #require(userCancelledAuthenticationError(original))

            #expect(rewritten.message == getDescriptionForError(.httpsAuthenticationFailed, ""))
            #expect(!rewritten.isRawMessage)
            #expect(rewritten.args == ["fetch", "origin"])
            #expect(rewritten.result.stderr == original.result.stderr)
            #expect(rewritten.result.gitError == nil)
        }

        @Test("leaves other errors alone")
        func leavesOthers() {
            #expect(userCancelledAuthenticationError(gitError("fatal: could not read Username for 'https://example.com': Device not configured\n")) == nil)
            #expect(userCancelledAuthenticationError(gitError("remote: hi\nfatal: could not read Username for 'x': terminal prompts disabled\n")) == nil)
            #expect(userCancelledAuthenticationError(gitError("fatal: could not read Username for 'x': terminal prompts disabled\nmore\n")) == nil)
            #expect(userCancelledAuthenticationError(CancellationError()) == nil)
        }

        @Test("recognizes SSH authentication failures")
        func sshAuthFailure() {
            #expect(isSSHAuthFailure(gitError("", gitError: .sshAuthenticationFailed)))
            #expect(isSSHAuthFailure(gitError("", gitError: .sshPermissionDenied)))
            #expect(!isSSHAuthFailure(gitError("", gitError: .httpsAuthenticationFailed)))
            #expect(!isSSHAuthFailure(CancellationError()))
        }
    }
}

// Ported from desktop/app/test/unit/git/credential-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/credential")
struct CredentialTests {
    @Suite("parseCredential")
    struct ParseCredential {
        @Test("expands arrays into numeric entries")
        func expandsArrays() {
            #expect(
                parseCredential("wwwauth[]=foo\nwwwauth[]=bar").entries == [
                    GitCredential.Entry(key: "wwwauth[0]", value: "foo"),
                    GitCredential.Entry(key: "wwwauth[1]", value: "bar"),
                ]
            )
        }

        @Test("splits on LF and CRLF, keeps everything after the first =, and skips other lines")
        func lines() {
            let cred = parseCredential("protocol=https\r\nhost=example.com\npassword=a=b\r\nnot a pair\n\nurl=\n")
            #expect(cred.entries == [
                GitCredential.Entry(key: "protocol", value: "https"),
                GitCredential.Entry(key: "host", value: "example.com"),
                GitCredential.Entry(key: "password", value: "a=b"),
                GitCredential.Entry(key: "url", value: ""),
            ])
        }

        @Test("keeps a repeated key's first position and last value, like a Map")
        func repeatedKeys() {
            let cred = parseCredential("username=a\nhost=h\nusername=b\n")
            #expect(cred.entries.map(\.key) == ["username", "host"])
            #expect(cred["username"] == "b")
        }

        @Test("numbers each array separately")
        func separateArrays() {
            let cred = parseCredential("capability[]=authtype\nwwwauth[]=Basic\ncapability[]=state\n")
            #expect(cred["capability[0]"] == "authtype")
            #expect(cred["capability[1]"] == "state")
            #expect(cred["wwwauth[0]"] == "Basic")
        }
    }

    @Suite("formatCredential")
    struct FormatCredential {
        @Test("round-trips what it parses")
        func roundTrip() throws {
            let text = "protocol=https\nhost=example.com\nwwwauth[]=Basic realm=\"x\"\nwwwauth[]=Bearer\nusername=joe\npassword=p=w\n"
            #expect(try formatCredential(parseCredential(text)) == text)
        }

        @Test("refuses values git's format can't hold")
        func forbiddenCharacters() {
            #expect(throws: ForbiddenCredentialCharactersError(key: "password")) {
                try formatCredential(GitCredential([("password", "line\nbreak")]))
            }
            #expect(throws: ForbiddenCredentialCharactersError(key: "password")) {
                try formatCredential(GitCredential([("password", "crlf\r\nbreak")]))
            }
            #expect(throws: ForbiddenCredentialCharactersError(key: "username")) {
                try formatCredential(GitCredential([("username", "nul\0")]))
            }
        }

        @Test("only unnumbers a trailing numbered index")
        func onlyTrailingIndex() throws {
            #expect(try formatCredential(GitCredential([("a[1]b", "x"), ("c[]", "y"), ("d[x]", "z")])) == "a[1]b=x\nc[]=y\nd[x]=z\n")
        }
    }

    @Suite("fill, approve, and reject")
    struct GitCredentialManager {
        /// Git Credential Manager with a plain-text store in a temporary
        /// directory, so nothing reaches the keychain and nothing prompts.
        func withGCM(_ body: (String) async throws -> Void) async throws {
            let store = try createTempDirectory()
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment["GCM_CREDENTIAL_STORE"] = "plaintext"
            runtime.processEnvironment["GCM_PLAINTEXT_STORE_PATH"] = store
            runtime.processEnvironment["GCM_ALLOW_UNSAFE_REMOTES"] = "true"
            runtime.processEnvironment["GCM_PROVIDER"] = "generic"
            runtime.processEnvironment["GCM_GUI_PROMPT"] = "0"
            runtime.processEnvironment["GCM_INTERACTIVE"] = "0"
            try await GitRuntime.withRuntime(runtime) {
                try await body(try createTempDirectory())
            }
        }

        @Test("stores, finds, and erases credentials in Git Credential Manager")
        func roundTrip() async throws {
            try await withGCM { path in
                let input = GitCredential([("protocol", "http"), ("host", "gcm.espalier.test:8080")])

                await #expect(throws: GitCredentialCommandError.self) {
                    try await fillCredential(input, path)
                }

                var credential = input
                credential["username"] = "joe"
                credential["password"] = "s3cret"
                try await approveCredential(credential, path)

                let filled = try await fillCredential(input, path)
                #expect(filled["username"] == "joe")
                #expect(filled["password"] == "s3cret")

                try await rejectCredential(credential, path)
                let error = await #expect(throws: GitCredentialCommandError.self) {
                    try await fillCredential(input, path)
                }
                #expect(error?.message.contains("terminal prompts disabled") == true)
            }
        }
    }
}

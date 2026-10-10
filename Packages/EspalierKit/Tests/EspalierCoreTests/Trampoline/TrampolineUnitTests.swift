@testable import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import TestSupport
import Testing

@Suite("Trampoline parts")
struct TrampolineUnitTests {
    @Suite("find-account")
    struct FindAccount {
        @Test("finds the account whose HTML origin matches the remote")
        func gitHubAccount() async throws {
            let dotCom = TrampolineAccount(endpoint: "https://api.github.com", login: "octocat", token: "a")
            let enterprise = TrampolineAccount(endpoint: "https://github.example.com/api/v3", login: "hubot", token: "b")
            let accounts = TestAccounts([dotCom, enterprise])

            #expect(try await findGitHubTrampolineAccount(accounts, "https://github.com/") == dotCom)
            #expect(try await findGitHubTrampolineAccount(accounts, "https://joe@github.example.com/owner/repo.git") == enterprise)
            #expect(try await findGitHubTrampolineAccount(accounts, "http://github.com/") == nil)
            #expect(try await findGitHubTrampolineAccount(accounts, "https://gitlab.com/") == nil)
        }

        @Test("finds a generic credential by the URL's username or the stored one")
        func genericAccount() throws {
            let suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let auth = GenericGitAuth(secrets: InMemorySecretStore(), defaults: defaults)
            let invocation = TrampolineInvocation(path: "/", isBackgroundTask: false, runtime: TestEnvironment.runtime)

            #expect(try findGenericTrampolineAccount(invocation, "https://git.example.com/", auth) == nil)

            try auth.setGenericCredential("https://git.example.com/", "joe", "s3cret")
            #expect(try findGenericTrampolineAccount(invocation, "https://git.example.com/", auth)
                == TrampolineAccount(endpoint: "https://git.example.com/", login: "joe", token: "s3cret"))
            // The URL's username wins, and has no password here.
            #expect(try findGenericTrampolineAccount(invocation, "https://jane@git.example.com/", auth) == nil)
        }

        @Test("reads each generic password once per git invocation")
        func memoizedPassword() throws {
            let invocation = TrampolineInvocation(path: "/", isBackgroundTask: false, runtime: TestEnvironment.runtime)
            let reads = TestCounter()
            for _ in 0..<3 {
                let password = try invocation.memoizedGetGenericPassword("https://e/", "joe") {
                    reads.increment()
                    return "pw"
                }
                #expect(password == "pw")
            }
            #expect(reads.value == 1)
            _ = try invocation.memoizedGetGenericPassword("https://e/", "jane") {
                reads.increment()
                return nil
            }
            #expect(reads.value == 2)
        }
    }

    @Suite("generic-git-auth")
    struct GenericAuth {
        @Test("keeps the username in the settings and the password in the keychain")
        func storage() throws {
            let suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let secrets = InMemorySecretStore()
            let auth = GenericGitAuth(secrets: secrets, defaults: defaults)

            try auth.setGenericCredential("https://git.example.com/", "joe", "s3cret")
            #expect(defaults.string(forKey: "genericGitAuth/username/https://git.example.com/") == "joe")
            #expect(try secrets.secret(service: "Espalier - https://git.example.com/", account: "joe") == "s3cret")
            #expect(auth.getGenericUsername("https://git.example.com/") == "joe")
            #expect(try auth.getGenericPassword("https://git.example.com/", "joe") == "s3cret")

            try auth.deleteGenericCredential("https://git.example.com/", "joe")
            #expect(auth.getGenericUsername("https://git.example.com/") == nil)
            #expect(try auth.getGenericPassword("https://git.example.com/", "joe") == nil)
        }
    }

    @Suite("TrampolineCommandParser")
    struct Parser {
        func request(forwardsStandardInput: Bool) -> TrampolineWire.Request {
            TrampolineWire.Request(
                kind: "hook",
                token: "token",
                workingDirectory: "/repo",
                arguments: ["/tmp/hooks/pre-push", "origin", "üñí"],
                environment: ["GIT_DIR": ".git", "GITHEAD_1": "x"],
                forwardsStandardInput: forwardsStandardInput
            )
        }

        @Test("parses a request and its standard input, byte by byte")
        func byteByByte() throws {
            let request = request(forwardsStandardInput: true)
            let stream = TrampolineWire.encode(.request, TrampolineWire.encodeRequest(request))
                + TrampolineWire.encode(.standardInput, Array("abc".utf8))
                + TrampolineWire.encode(.standardInput, [UInt8]())
                + TrampolineWire.encode(.standardInputEnd)

            var parser = TrampolineCommandParser(maximumStandardInputLength: 100)
            var events: [TrampolineCommandParser.Event] = []
            for byte in stream {
                events += try parser.process([byte])
            }

            #expect(events == [.request(request), .standardInput(Array("abc".utf8)), .standardInput([]), .standardInputEnd])
            #expect(parser.hasFinished)
        }

        @Test("finishes after a request without standard input")
        func noStandardInput() throws {
            var parser = TrampolineCommandParser(maximumStandardInputLength: 100)
            let events = try parser.process(TrampolineWire.encode(.request, TrampolineWire.encodeRequest(request(forwardsStandardInput: false))))
            #expect(events.count == 1)
            #expect(parser.hasFinished)
            #expect(throws: TrampolineCommandParser.ParseError.unexpectedFrame(.standardInputEnd, .finished)) {
                try parser.process(TrampolineWire.encode(.standardInputEnd))
            }
        }

        @Test("limits standard input")
        func standardInputLimit() throws {
            var parser = TrampolineCommandParser(maximumStandardInputLength: 4)
            _ = try parser.process(TrampolineWire.encode(.request, TrampolineWire.encodeRequest(request(forwardsStandardInput: true))))
            _ = try parser.process(TrampolineWire.encode(.standardInput, [1, 2, 3]))
            #expect(throws: TrampolineCommandParser.ParseError.standardInputTooLarge) {
                try parser.process(TrampolineWire.encode(.standardInput, [4, 5]))
            }
        }

        @Test("rejects counts the payload can't hold")
        func impossibleCounts() {
            var payload: [UInt8] = [0, 1]
            for string in ["askpass", "token", "/"] {
                payload += [0, 0, 0, UInt8(string.utf8.count)] + Array(string.utf8)
            }
            payload += [0xFF, 0xFF, 0xFF, 0xFF]
            #expect(throws: TrampolineWire.DecodingError.malformedRequest) {
                try TrampolineWire.decodeRequest(payload)
            }
        }

        @Test("round-trips exit codes")
        func exitCodes() throws {
            for code: Int32 in [0, 1, 128, -1, .max, .min] {
                #expect(try TrampolineWire.decodeExitCode(TrampolineWire.encodeExitCode(code)) == code)
            }
            #expect(throws: TrampolineWire.DecodingError.malformedExitCode) {
                try TrampolineWire.decodeExitCode([0, 0])
            }
        }
    }
}

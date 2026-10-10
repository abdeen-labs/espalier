// Ported from desktop/app/test/unit/git/remote-discovery-test.ts
//
// Each test runs inside `withIsolatedGitConfig`.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A URL separator case, named for the test.
struct URLSeparatorCase: Sendable, CustomTestStringConvertible {
    let description: String
    let separator: String

    var testDescription: String { description }

    static let all = [
        URLSeparatorCase(description: "line separator", separator: "\u{2028}"),
        URLSeparatorCase(description: "carriage return", separator: "\r"),
        URLSeparatorCase(description: "line feed", separator: "\n"),
        URLSeparatorCase(description: "CRLF", separator: "\r\n"),
    ]
}

@Suite("git/remote discovery")
struct RemoteDiscoveryTests {
    @Test("preserves a URL containing a separator", arguments: URLSeparatorCase.all)
    func preservesSeparators(_ testCase: URLSeparatorCase) async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let url = "/path/with\(testCase.separator)more\t/another-path (fetch)"
            try await setConfigValue(repository, "remote.origin.url", url)

            let remotes = try await getRemotes(repository)
            #expect(remotes.count == 1)
            #expect(remotes.first?.name == "origin")
            #expect(remotes.first.map { JSCompat.strictEquals($0.url, url) } == true)
        }
    }

    @Test("preserves whitespace at both ends of a URL")
    func preservesWhitespace() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let url = " \t/path/with spaces\t \r\n"
            try await setConfigValue(repository, "remote.origin.url", url)

            let remotes = try await getRemotes(repository)
            #expect(remotes.map(\.name) == ["origin"])
            #expect(remotes.first.map { JSCompat.strictEquals($0.url, url) } == true)
            let remoteURL = try await getRemoteURL(repository, "origin")
            #expect(remoteURL.map { JSCompat.strictEquals($0, url) } == true)
        }
    }

    @Test("returns each configured remote once in alphabetical order")
    func eachRemoteOnce() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let names = ["z-last", "origin", "has.dots", "--remote", "A"]
            for name in names {
                try await setConfigValue(repository, "remote.\(name).url", "/fetch/\(name)")
                try await git(
                    ["config", "--add", "remote.\(name).url", "/second/\(name)"],
                    repository.path,
                    "add another fetch URL"
                )
                try await setConfigValue(repository, "remote.\(name).pushurl", "/push/\(name)")
            }

            #expect(
                try await getRemotes(repository)
                    == names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                    .map { Remote(name: $0, url: "/fetch/\($0)") }
            )
        }
    }

    @Test("preserves separators in configured remote names")
    func separatorsInNames() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let name = "remote\u{2028}with\u{2029}separators\tand.dots"
            try await setConfigValue(repository, "remote.\(name).url", "/fetch")

            #expect(try await getRemotes(repository) == [Remote(name: name, url: "/fetch")])
        }
    }

    @Test("resolves fetch URL rewrites without using the push URL")
    func urlRewrites() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await setConfigValue(repository, "url./resolved/.insteadOf", "desktop-remote-test:")
            try await setConfigValue(repository, "url./longer-match/.insteadOf", "desktop-remote-test:project/")
            try await setConfigValue(repository, "remote.origin.url", "desktop-remote-test:project/repository")
            try await setConfigValue(repository, "remote.origin.pushurl", "/push-only")

            #expect(try await getRemotes(repository) == [Remote(name: "origin", url: "/longer-match/repository")])
        }
    }

    @Test("reads remotes and URL rewrites from included configuration")
    func includedConfiguration() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let includedConfig = POSIXPath.join(repository.path, ".git", "included-config")
            try Data((
                "[remote \"included\"]\nurl = desktop-remote-test:repository\n"
                    + "[url \"/resolved/\"]\ninsteadOf = desktop-remote-test:\n"
            ).utf8).write(to: URL(filePath: includedConfig))
            try await setConfigValue(repository, "include.path", includedConfig)

            #expect(try await getRemotes(repository) == [Remote(name: "included", url: "/resolved/repository")])
        }
    }

    @Test("lists unused remotes without changing credential policy", arguments: [false, true])
    func credentialPolicy(_ rewritten: Bool) async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let originURL = "https://example.invalid/healthy.git"
            let unusedURL = "https://fixture-user:fixture-password@example.invalid/unused.git"
            try await setConfigValue(repository, "remote.origin.url", originURL)
            try await setConfigValue(
                repository,
                "remote.unused.url",
                rewritten ? "desktop-remote-test:unused.git" : unusedURL
            )
            if rewritten {
                try await setConfigValue(
                    repository,
                    "url.https://fixture-user:fixture-password@example.invalid/.insteadOf",
                    "desktop-remote-test:"
                )
            }
            try await setConfigValue(repository, "transfer.credentialsInUrl", "die")
            // Keep the test offline even if credential validation stops rejecting.
            try await setConfigValue(repository, "protocol.allow", "never")

            #expect(try await getRemotes(repository) == [
                Remote(name: "origin", url: originURL),
                Remote(name: "unused", url: unusedURL),
            ])
            #expect(try await getConfigValue(repository, "transfer.credentialsInUrl") == "die")

            let result = try await git(
                ["fetch", "--", "unused"],
                repository.path,
                "verify transfer credential policy",
                options: GitExecutionOptions(successExitCodes: [128])
            )
            #expect(result.stderr.contains("uses plaintext credentials"))
        }
    }

    @Test("reads scope remotes only when inside a repository", arguments: ["global", "system"])
    func scopedRemotes(_ scope: String) async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let config = POSIXPath.join(repository.path, ".git", "\(scope)-config")
            try Data((
                "[remote \"\(scope)\"]\nurl = desktop-remote-test:repository\n"
                    + "[url \"/\(scope)/\"]\ninsteadOf = desktop-remote-test:\n"
            ).utf8).write(to: URL(filePath: config))
            let env: [String: String?] = scope == "global"
                ? ["GIT_CONFIG_GLOBAL": config]
                : ["GIT_CONFIG_SYSTEM": config, "GIT_CONFIG_NOSYSTEM": "0"]

            try await withGitEnvironment(env) { () async throws in
                let remotes = try await getRemotes(repository)
                #expect(remotes == [Remote(name: scope, url: "/\(scope)/repository")])
                let outside = try await getRemotes(try setupEmptyDirectory())
                #expect(outside.isEmpty)
            }
        }
    }

    @Test("returns partial clone URLs without display annotations")
    func partialCloneURLs() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await setConfigValue(repository, "remote.origin.url", "/fetch")
            try await setConfigValue(repository, "remote.origin.promisor", "true")
            try await setConfigValue(repository, "remote.origin.partialclonefilter", "blob:none")

            #expect(try await getRemotes(repository) == [Remote(name: "origin", url: "/fetch")])
        }
    }

    @Test("omits remotes without a fetch URL")
    func omitsRemotesWithoutFetchURL() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try await setConfigValue(repository, "remote.empty.url", "")
            try await setConfigValue(repository, "remote.push-only.pushurl", "/push")
            try await setConfigValue(repository, "remote.fetch-only.fetch", "+refs/heads/*:refs/remotes/fetch-only/*")
            try await setConfigValue(repository, "remote.origin.url", "/fetch")

            #expect(try await getRemotes(repository) == [Remote(name: "origin", url: "/fetch")])
        }
    }

    @Test("honors empty URL entries that reset previous URLs")
    func emptyURLEntries() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            for name in ["cleared", "replaced"] {
                for url in ["/original", ""] {
                    try await git(
                        ["config", "--add", "remote.\(name).url", url],
                        repository.path,
                        "configure remote URL"
                    )
                }
            }
            try await git(
                ["config", "--add", "remote.replaced.url", "/replacement"],
                repository.path,
                "configure replacement URL"
            )

            #expect(try await getRemotes(repository) == [Remote(name: "replaced", url: "/replacement")])
        }
    }

    @Test("returns no remotes for an empty repository")
    func emptyRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            #expect(try await getRemotes(repository).isEmpty)
        }
    }

    @Test("reports invalid repository configuration")
    func invalidConfiguration() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try Data("[invalid".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, ".git", "config")))

            await expectError(matching: "bad config") {
                _ = try await getRemotes(repository)
            }
            await expectError(matching: "bad config") {
                _ = try await getRemoteURL(repository, "origin")
            }
        }
    }

    @Test("reports a remote URL without a configured value")
    func missingValue() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            try Data("[remote \"origin\"]\nurl\n".utf8).write(
                to: URL(filePath: POSIXPath.join(repository.path, ".git", "config"))
            )

            await expectError(matching: "Remote URL configuration is missing a value") {
                _ = try await getRemotes(repository)
            }
        }
    }

    // MARK: - Espalier

    @Test("sorts names by UTF-16 code units, as JavaScript does")
    func utf16Order() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            // U+1F600 sorts before U+FF21 in UTF-16 (a surrogate pair starts
            // with 0xD83D) but after it by scalar value.
            for name in ["\u{FF21}", "\u{1F600}", "b"] {
                try await setConfigValue(repository, "remote.\(name).url", "/\(name)")
            }
            #expect(try await getRemotes(repository).map(\.name) == ["b", "\u{1F600}", "\u{FF21}"])
        }
    }
}

/// Expects `operation` to throw an error whose message contains `text`.
private func expectError(matching text: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected an error matching \(text)")
    } catch {
        #expect("\(error)".contains(text), "\(error)")
    }
}

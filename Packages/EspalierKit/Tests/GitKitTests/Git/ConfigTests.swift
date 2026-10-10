// Ported from desktop/app/test/unit/git/config-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// One of the generated "rejects non-exact directory ..." cases.
struct NonExactDirectoryCase: Sendable, CustomTestStringConvertible {
    let value: String

    /// `JSON.stringify(value)`.
    var testDescription: String { "\"\(value)\"" }

    static let all = ["*", "/*", "~/repository", "%(prefix)/repository"]
        .map(NonExactDirectoryCase.init(value:))
}

private func readFile(_ path: String) throws -> String {
    try String(contentsOf: URL(filePath: path), encoding: .utf8)
}

@Suite("git/config")
struct ConfigTests {
    @Suite("addSafeDirectory")
    struct AddSafeDirectory {
        @Test("rejects non-exact directory", arguments: NonExactDirectoryCase.all)
        func rejectsNonExactDirectory(_ testCase: NonExactDirectoryCase) async throws {
            try await withOwnershipCheck { configPath in
                let before = try readFile(configPath)

                await #expect(throws: (any Error).self) {
                    try await addSafeDirectory(testCase.value)
                }

                #expect(try readFile(configPath) == before)
            }
        }

        @Test("rejects an existing directory whose name denotes a subtree")
        func rejectsSubtreeDirectory() async throws {
            let parent = try createTempDirectory()
            let directory = POSIXPath.join(parent, "*")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            try await withOwnershipCheck { configPath in
                let before = try readFile(configPath)

                await #expect(throws: (any Error).self) {
                    try await addSafeDirectory("\(directory)/")
                }

                #expect(try readFile(configPath) == before)
            }
        }
    }

    @Suite("config")
    struct Config {
        @Test("looks up config values")
        func looksUpConfigValues() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)
            let bare = try await getConfigValue(repository, "core.bare")
            #expect(bare == "false")
        }

        @Test("returns null for undefined values")
        func nullForUndefinedValues() async throws {
            let testRepoPath = try setupFixtureRepository("test-repo")
            let repository = Repository(path: testRepoPath)
            let value = try await getConfigValue(repository, "core.the-meaning-of-life")
            #expect(value == nil)
        }
    }

    @Suite("global config")
    struct GlobalConfig {
        struct Setup {
            let env: [String: String]
            let expectedConfigPath: String
            let baseArgs: [String]
            let home: String
        }

        static func setup() throws -> Setup {
            let home = try createTempDirectory()
            let env = ["HOME": home]
            let expectedConfigPath = POSIXPath.normalize(POSIXPath.join(home, ".gitconfig"))
            let baseArgs = ["config", "-f", expectedConfigPath]

            return Setup(env: env, expectedConfigPath: expectedConfigPath, baseArgs: baseArgs, home: home)
        }

        @Suite("getGlobalConfigPath")
        struct GetGlobalConfigPath {
            @Test("gets the config path")
            func getsConfigPath() async throws {
                let s = try GlobalConfig.setup()

                // getGlobalConfigPath requires at least one entry, so the
                // test needs to setup an existing config value
                _ = try await Dugite.exec(s.baseArgs + ["user.name", "bar"], s.home)

                let path = try await getGlobalConfigPath(env: s.env)
                let expected = try #require(realpath(s.expectedConfigPath, nil))
                defer { free(expected) }
                #expect(path == String(cString: expected))
            }
        }

        @Suite("setGlobalConfigValue")
        struct SetGlobalConfigValue {
            @Test("will replace all entries for a global value")
            func replacesAllEntries() async throws {
                let s = try GlobalConfig.setup()
                let key = "foo.bar"

                _ = try await Dugite.exec(s.baseArgs + ["--add", key, "first"], s.home)
                _ = try await Dugite.exec(s.baseArgs + ["--add", key, "second"], s.home)

                try await setGlobalConfigValue(key, "the correct value", env: s.env)
                let value = try await getGlobalConfigValue(key, env: s.env)
                #expect(value == "the correct value")
            }
        }

        @Suite("getGlobalBooleanConfigValue")
        struct GetGlobalBooleanConfigValue {
            let key = "foo.bar"

            @Test("reads git's boolean spellings", arguments: [
                NamedCase("treats \"off\" as false", (configured: "off", expected: false)),
                NamedCase("treats \"true\" as true", (configured: "true", expected: true)),
            ])
            func booleans(_ testCase: NamedCase<(configured: String, expected: Bool)>) async throws {
                let (configured, expected) = testCase.value
                let s = try GlobalConfig.setup()
                try await setGlobalConfigValue(key, configured, env: s.env)
                #expect(try await getGlobalBooleanConfigValue(key, env: s.env) == expected)
            }
        }
    }
}

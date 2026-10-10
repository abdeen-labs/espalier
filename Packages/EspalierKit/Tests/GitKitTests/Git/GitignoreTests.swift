// Ported from desktop/app/test/unit/git/gitignore-test.ts
//
// GitGitignore.swift ends the text with CRLF when core.autocrlf is true,
// adds no blank lines with core.autocrlf and core.safecrlf both true, and
// saves empty contents without a .gitignore. The "appends ..." tests run
// with core.autocrlf=true, so they expect a CRLF ending.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func writeFile(_ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: path))
}

private func readFile(_ path: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self)
}

private func symlink(_ target: String, _ path: String) throws {
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
}

/// Expects `operation` to fail with the symbolic link error.
private func expectSymbolicLinkError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
) async {
    let error = await #expect(throws: GitLibError.self, sourceLocation: sourceLocation) {
        try await operation()
    }
    #expect(
        error?.message.contains("Cannot use a symbolic link as the root .gitignore file") == true,
        sourceLocation: sourceLocation
    )
}

@Suite("gitignore")
struct GitignoreTests {
    @Suite("readGitIgnoreAtRoot")
    struct ReadGitIgnoreAtRoot {
        @Test("returns null when .gitignore does not exist on disk")
        func nullWhenMissing() async throws {
            let repo = try setupEmptyRepository()

            let gitignore = try await readGitIgnoreAtRoot(repo)

            #expect(gitignore == nil)
        }

        @Test("reads contents from disk")
        func readsContents() async throws {
            let repo = try setupEmptyRepository()
            let path = repo.path

            let expected = "node_modules\nyarn-error.log\n"

            let ignoreFile = "\(path)/.gitignore"
            try writeFile(ignoreFile, expected)

            let gitignore = try await readGitIgnoreAtRoot(repo)

            #expect(gitignore == expected)
        }

        @Test("rejects a symbolic link")
        func rejectsSymbolicLink() async throws {
            let repo = try setupEmptyRepository()
            let targetPath = POSIXPath.join(repo.path, "target")

            try writeFile(targetPath, "target contents")
            try symlink(targetPath, POSIXPath.join(repo.path, ".gitignore"))

            await expectSymbolicLinkError {
                _ = try await readGitIgnoreAtRoot(repo)
            }
        }

        @Test("rejects a dangling symbolic link")
        func rejectsDanglingSymbolicLink() async throws {
            let repo = try setupEmptyRepository()
            let targetPath = POSIXPath.join(repo.path, "missing-target")

            try symlink(targetPath, POSIXPath.join(repo.path, ".gitignore"))

            await expectSymbolicLinkError {
                _ = try await readGitIgnoreAtRoot(repo)
            }
        }

        @Test("when autocrlf=true and safecrlf=true, appends CRLF to file")
        func autocrlfAndSafecrlfAppendCRLF() async throws {
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [
                ("core.autocrlf", "true"),
                ("core.safecrlf", "true"),
            ])

            let path = repo.path

            try await saveGitIgnore(repo, "node_modules")
            _ = try await Dugite.exec(["add", ".gitignore"], path)

            let commit = try await Dugite.exec(["commit", "-m", "create the ignore file"], path)
            #expect(commit.exitCode == 0)

            let contents = try #require(try await readGitIgnoreAtRoot(repo))
            #expect(JSCompat.endsWith(contents, "\r\n"))
        }

        @Test("when autocrlf=input, appends LF to file")
        func autocrlfInputAppendsLF() async throws {
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [
                // ensure this repository only ever sticks to LF
                ("core.eol", "lf"),
                // do not do any conversion of line endings when committing
                ("core.autocrlf", "input"),
            ])

            let path = repo.path

            try await saveGitIgnore(repo, "node_modules")
            _ = try await Dugite.exec(["add", ".gitignore"], path)

            let commit = try await Dugite.exec(["commit", "-m", "create the ignore file"], path)
            #expect(commit.exitCode == 0)

            let contents = try #require(try await readGitIgnoreAtRoot(repo))
            #expect(JSCompat.endsWith(contents, "\n"))
            // LF, not CRLF.
            #expect(!JSCompat.endsWith(contents, "\r\n"))
        }
    }

    @Suite("saveGitIgnore")
    struct SaveGitIgnore {
        @Test("creates gitignore file when it doesn't exist")
        func createsFile() async throws {
            let repo = try setupEmptyRepository()

            try await saveGitIgnore(repo, "node_modules\n")

            let exists = await pathExists("\(repo.path)/.gitignore")

            #expect(exists)
        }

        @Test("rejects a symbolic link without modifying its target")
        func rejectsSymbolicLinkWithoutModifyingTarget() async throws {
            let repo = try setupEmptyRepository()
            let targetPath = POSIXPath.join(repo.path, "target")

            try writeFile(targetPath, "target contents")
            try symlink(targetPath, POSIXPath.join(repo.path, ".gitignore"))

            await expectSymbolicLinkError {
                try await saveGitIgnore(repo, "node_modules\n")
            }
            #expect(try readFile(targetPath) == "target contents")
        }

        @Test("rejects a dangling symbolic link")
        func rejectsDanglingSymbolicLink() async throws {
            let repo = try setupEmptyRepository()
            let targetPath = POSIXPath.join(repo.path, "missing-target")

            try symlink(targetPath, POSIXPath.join(repo.path, ".gitignore"))

            await expectSymbolicLinkError {
                try await saveGitIgnore(repo, "node_modules\n")
            }
        }

        @Test("deletes gitignore file when no entries provided")
        func deletesFileWhenEmpty() async throws {
            let repo = try setupEmptyRepository()
            let path = repo.path

            let ignoreFile = "\(path)/.gitignore"
            try writeFile(ignoreFile, "node_modules\n")

            // update gitignore file to be empty
            try await saveGitIgnore(repo, "")

            let exists = await pathExists(ignoreFile)
            #expect(!exists)
        }

        @Test("succeeds when no entries provided and no gitignore file exists")
        func emptyWithoutFileSucceeds() async throws {
            let repo = try setupEmptyRepository()

            try await saveGitIgnore(repo, "")

            #expect(await !pathExists("\(repo.path)/.gitignore"))
        }

        @Test("applies rule correctly to repository")
        func appliesRule() async throws {
            let repo = try setupEmptyRepository()

            let path = repo.path

            try await saveGitIgnore(repo, "*.txt\n")
            _ = try await Dugite.exec(["add", ".gitignore"], path)
            _ = try await Dugite.exec(["commit", "-m", "create the ignore file"], path)

            // Create a txt file
            let file = POSIXPath.join(repo.path, "a.txt")

            try writeFile(file, "thrvbnmerkl;,iuw")

            // Check status of repo
            let status = try await getStatusOrThrow(repo)
            let files = status.workingDirectory.files

            #expect(files.count == 0)
        }

        // A backslash is escaped too; left as it is, git would read it as
        // escaping the character after it.
        @Test("escapes string with special git characters")
        func escapesSpecialCharacters() {
            let unescapedFilePath = "[never]\\!gonna*give#you?_.up"
            let escapedFilePath = "\\[never\\]\\\\\\!gonna\\*give\\#you\\?_.up"

            let result = escapeGitSpecialCharacters(unescapedFilePath)
            #expect(result == escapedFilePath)
        }

        // A backslash, which escapes the next character in a rule, and
        // trailing spaces, which git drops from one.
        @Test("escapes backslashes and trailing spaces")
        func escapesBackslashesAndTrailingSpaces() {
            #expect(escapeGitSpecialCharacters("back\\slash.txt") == "back\\\\slash.txt")
            #expect(escapeGitSpecialCharacters("two spaces  ") == "two spaces\\ \\ ")
            #expect(escapeGitSpecialCharacters(" leading") == " leading")
        }

        // The rule for a file ignores that file and no other.
        @Test(
            "ignoring a file by name ignores only that file",
            arguments: [
                PatternPath("a*.txt", decoy: "ab.txt"),
                PatternPath("[ab].txt", decoy: "a.txt"),
                PatternPath("back\\slash.txt", decoy: "backslash.txt"),
                PatternPath("trailing space ", decoy: "trailing space"),
                PatternPath("#hash.txt", decoy: "hash.txt"),
                PatternPath("!bang.txt", decoy: "bang.txt"),
            ]
        )
        func ignoresOnlyTheFile(_ path: PatternPath) async throws {
            let repo = try setupEmptyRepository()
            try writeFileExactly(path.name, "name\n", in: repo.path)
            try writeFileExactly(path.decoy, "decoy\n", in: repo.path)

            try await appendIgnoreFile(repo, [path.name])

            let untracked = try await getStatusOrThrow(repo).workingDirectory.files.map(\.path)
            #expect(Set(untracked) == [".gitignore", path.decoy])
        }

        // Written over two lines, the name would make two rules, neither of
        // them the file's.
        @Test("a name with a line break can't be ignored, and the .gitignore stays as it was", arguments: ["new\nline.txt", "carriage\rreturn.txt"])
        func refusesLineBreaks(_ name: String) async throws {
            let repo = try setupEmptyRepository()
            let ignoreFile = "\(repo.path)/.gitignore"
            try writeFile(ignoreFile, "node_modules\n")

            await #expect(throws: GitLibError.self) {
                try await appendIgnoreFile(repo, ["other.txt", name])
            }
            #expect(try readFile(ignoreFile) == "node_modules\n")
        }
    }

    @Suite("appendIgnoreRule")
    struct AppendIgnoreRule {
        @Test("appends rules", arguments: [
            // With core.autocrlf=true the text ends with CRLF.
            NamedCase("appends one rule", (
                rules: ["yarn-error.log"],
                expected: "node_modules\nyarn-error.log\r\n"
            )),
            // A final CRLF; see "appends one rule".
            NamedCase("appends multiple rules", (
                rules: ["yarn-error.log", ".eslintcache", "dist/"],
                expected: "node_modules\nyarn-error.log\n.eslintcache\ndist/\r\n"
            )),
        ])
        func appendsRules(_ testCase: NamedCase<(rules: [String], expected: String)>) async throws {
            let (rules, expected) = testCase.value
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [("core.autocrlf", "true")])

            let path = repo.path

            let ignoreFile = "\(path)/.gitignore"
            try writeFile(ignoreFile, "node_modules\n")

            try await appendIgnoreRule(repo, rules)

            let gitignore = try readFile(ignoreFile)
            #expect(gitignore == expected)
        }

        @Test("appends one file containing special characters")
        func appendsFileWithSpecialCharacters() async throws {
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [("core.autocrlf", "true")])

            let path = repo.path

            let ignoreFile = "\(path)/.gitignore"
            try writeFile(ignoreFile, "node_modules\n")

            let fileToIgnore = "[never]!gonna*give#you?_.up"
            try await appendIgnoreFile(repo, [fileToIgnore])

            let gitignore = try readFile(ignoreFile)

            // A final CRLF; see "appends one rule".
            let expected = "node_modules\n" + "\\[never\\]\\!gonna\\*give\\#you\\?_.up\r\n"
            #expect(gitignore == expected)
        }

        @Test("appends LF when core.autocrlf is false or input", arguments: ["false", "input"])
        func appendsLFWithoutAutocrlf(_ autocrlf: String) async throws {
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [("core.autocrlf", autocrlf)])

            let ignoreFile = "\(repo.path)/.gitignore"
            try writeFile(ignoreFile, "node_modules\n")

            try await appendIgnoreRule(repo, ["yarn-error.log"])

            #expect(try readFile(ignoreFile) == "node_modules\nyarn-error.log\n")
        }

        // Formatting the contents again mustn't append another CRLF.
        @Test("does not add blank lines when autocrlf=true and safecrlf=true")
        func noBlankLinesWithAutocrlfAndSafecrlf() async throws {
            let repo = try setupEmptyRepository()

            try await setupLocalConfig(repo, [
                ("core.autocrlf", "true"),
                ("core.safecrlf", "true"),
            ])

            let ignoreFile = "\(repo.path)/.gitignore"

            try await appendIgnoreRule(repo, ["node_modules"])
            #expect(try readFile(ignoreFile) == "node_modules\r\n")

            try await appendIgnoreRule(repo, ["yarn-error.log", "dist/"])
            #expect(try readFile(ignoreFile) == "node_modules\r\nyarn-error.log\r\ndist/\r\n")

            try await saveGitIgnore(repo, try #require(try await readGitIgnoreAtRoot(repo)))
            #expect(try readFile(ignoreFile) == "node_modules\r\nyarn-error.log\r\ndist/\r\n")
        }
    }
}

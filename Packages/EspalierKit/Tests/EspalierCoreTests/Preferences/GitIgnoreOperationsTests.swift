// These drive the repository model's gitignore operations against real
// repositories (GitKitTests has the git half), and the menu items as data.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Gitignore menu items")
struct GitIgnoreMenuItemsTests {
    @Test("one file at the root: ignore the file, and its extension")
    func rootFile() {
        #expect(gitIgnoreMenuItems(for: ["debug.log"]).map(\.action) == [.files(["debug.log"]), .patterns(["*.log"])])
    }

    // Unescaped, `*.t[x]t` would also ignore every .txt file.
    @Test("an extension with pattern characters is escaped in its rule")
    func extensionWithPatternCharacters() {
        #expect(gitIgnoreMenuItems(for: ["notes.t[x]t"]).last?.action == .patterns(["*.t\\[x\\]t"]))
    }

    @Test("one file in a folder: also each folder above it, innermost first")
    func nestedFile() {
        let items = gitIgnoreMenuItems(for: ["src/app/main.swift"])
        #expect(items.map(\.action) == [.files(["src/app/main.swift"]), nil, .patterns(["*.swift"])])
        #expect(items.dropFirst().first?.submenu.map(\.action) == [.files(["/src/app"]), .files(["/src"])])
    }

    @Test("a .gitignore file can't be ignored, nor its folder from its menu")
    func gitIgnoreFile() {
        let root = gitIgnoreMenuItems(for: [".gitignore"])
        #expect(root.map(\.action) == [.files([".gitignore"])])
        #expect(root.map(\.isEnabled) == [false])
        let nested = gitIgnoreMenuItems(for: ["docs/.gitignore"])
        #expect(nested.map(\.isEnabled) == [false, false])
    }

    @Test("several files: ignore them all but .gitignore files, and up to five of their extensions")
    func severalFiles() {
        let paths = [
            "a.txt", ".gitignore", "b/c.md", "Makefile", "d.txt", "e.tar.gz", "f.json", "g.png", "h.yml", "i.rb",
        ]
        let items = gitIgnoreMenuItems(for: paths)
        #expect(items.first?.action == .files(["a.txt", "b/c.md", "Makefile", "d.txt", "e.tar.gz", "f.json", "g.png", "h.yml", "i.rb"]))
        #expect(items.first?.isEnabled == true)
        #expect(items.dropFirst().map(\.action) == [
            .patterns(["*.txt"]),
            .patterns(["*.md"]),
            .patterns(["*.gz"]),
            .patterns(["*.json"]),
            .patterns(["*.png"]),
        ])
    }

    @Test("several .gitignore files: nothing to ignore")
    func onlyGitIgnoreFiles() {
        let items = gitIgnoreMenuItems(for: [".gitignore", "a/.gitignore"])
        #expect(items.map(\.action) == [.files([])])
        #expect(items.map(\.isEnabled) == [false])
        #expect(gitIgnoreMenuItems(for: []).isEmpty)
    }
}

@Suite("Gitignore operations", .offline) @MainActor
struct GitIgnoreOperationsTests {
    @Test("refuses a .gitignore that is a symbolic link, leaving its target alone")
    func symbolicLink() async throws {
        let fixture = try await makeSelectedRepository()
        try fixture.write("target", "target contents")
        try FileManager.default.createSymbolicLink(
            atPath: POSIXPath.join(fixture.local.path, ".gitignore"),
            withDestinationPath: POSIXPath.join(fixture.local.path, "target")
        )

        await #expect(throws: OperationError.self) {
            try await fixture.model.readGitIgnore()
        }

        let saveError = await #expect(throws: OperationError.self) {
            try await fixture.model.saveGitIgnore("node_modules\n")
        }
        #expect(saveError?.operation == .saveGitIgnore)
        await #expect(throws: OperationError.self) {
            try await fixture.model.ignore(.patterns(["*.log"]))
        }
        #expect(try fixture.read("target") == "target contents")
        await fixture.app.idle()
    }

    @Test("saves the .gitignore and returns once the changes list shows it")
    func saves() async throws {
        let fixture = try await makeSelectedRepository()
        try fixture.write("debug.log", "log\n")
        await fixture.model.refresh(.status, reason: .user)
        #expect(changedPaths(fixture) == ["debug.log"])

        try await fixture.model.saveGitIgnore("*.log")

        #expect(try fixture.read(".gitignore") == "*.log\n")
        #expect(changedPaths(fixture) == [".gitignore"])

        try await fixture.model.saveGitIgnore("*.tmp\n")
        #expect(try fixture.read(".gitignore") == "*.tmp\n")
        #expect(changedPaths(fixture) == [".gitignore", "debug.log"])
        await fixture.app.idle()
    }

    @Test("saving nothing deletes the .gitignore, and is fine when there is none")
    func savesNothing() async throws {
        let fixture = try await makeSelectedRepository()
        try await fixture.model.saveGitIgnore("")
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".gitignore")))

        try await fixture.model.saveGitIgnore("*.log\n")
        try await fixture.model.saveGitIgnore("")
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".gitignore")))
        #expect(changedPaths(fixture).isEmpty)
        await fixture.app.idle()
    }

    @Test("ignores files by escaped path, and they leave the changes list")
    func ignoresFiles() async throws {
        let fixture = try await makeSelectedRepository()
        try fixture.write("build/output [1].txt", "out\n")
        try fixture.write("notes#draft?.md", "notes\n")
        try fixture.write("keep.txt", "keep\n")
        await fixture.model.refresh(.status, reason: .user)

        try await fixture.model.ignore(.files(["build/output [1].txt", "notes#draft?.md"]))

        #expect(try fixture.read(".gitignore") == "build/output \\[1\\].txt\nnotes\\#draft\\?.md\n")
        #expect(changedPaths(fixture) == [".gitignore", "keep.txt"])
        await fixture.app.idle()
    }

    @Test("ignores a folder from the menu, and a pattern, appending to what's there")
    func ignoresFolderAndPattern() async throws {
        let fixture = try await makeSelectedRepository()
        try fixture.write(".gitignore", "node_modules")
        try fixture.write("logs/today.log", "log\n")
        try fixture.write("other.log", "log\n")
        try fixture.write("src/a.tmp", "tmp\n")
        await fixture.model.refresh(.status, reason: .user)

        let menu = fixture.model.gitIgnoreMenuItems(for: ["logs/today.log"])
        let folder = try #require(menu.first { !$0.submenu.isEmpty }?.submenu.first)
        try await fixture.model.ignore(try #require(folder.action))
        try await fixture.model.ignore(.patterns(["*.tmp"]))

        #expect(try fixture.read(".gitignore") == "node_modules\n/logs\n*.tmp\n")
        #expect(changedPaths(fixture) == [".gitignore", "other.log"])
        await fixture.app.idle()
    }

    @Test("with core.autocrlf and core.safecrlf, every line ends in CRLF and no blank lines pile up")
    func crlf() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await setupLocalConfig(local, [("core.autocrlf", "true"), ("core.safecrlf", "true")])
        }

        try await fixture.model.saveGitIgnore("node_modules")
        try await fixture.model.ignore(.patterns(["*.log"]))
        try await fixture.model.ignore(.files(["build"]))

        // One CRLF per line, however many formatting passes an append makes.
        #expect(try fixture.read(".gitignore") == "node_modules\r\n*.log\r\nbuild\r\n")
        // Git accepts it under safecrlf.
        try await runGit(["add", ".gitignore"], fixture.local)
        await fixture.app.idle()
    }

    @Test("ends the file with LF unless lines end in CRLF", arguments: [nil, "input", "true"] as [String?])
    func lineEndings(autocrlf: String?) async throws {
        let fixture = try await makeSelectedRepository { local in
            if let autocrlf {
                try await setupLocalConfig(local, [("core.autocrlf", autocrlf)])
            }
        }

        try await fixture.model.saveGitIgnore("node_modules")
        try await fixture.model.ignore(.patterns(["*.log"]))

        // CRLF only for true; LF for input and none.
        let ending = autocrlf == "true" ? "\r\n" : "\n"
        #expect(try fixture.read(".gitignore") == "node_modules\(ending)*.log\(ending)")
        await fixture.app.idle()
    }

    @Test("has no ignore items while a rebase waits on conflicts")
    func rebaseConflicts() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "feature"], local)
            try await commitFile(local, "README.md", "# feature\n")
            try await runGit(["checkout", "main"], local)
            try await commitFile(local, "README.md", "# main\n")
            try await runGit(["checkout", "feature"], local)
            _ = try await runGitAllowingFailure(["rebase", "main"], local)
        }
        await fixture.model.refresh(.full, reason: .user)
        await fixture.model.operations.enrichmentIdle()

        guard case .rebase? = fixture.model.operations.conflictState else {
            Issue.record("Expected a rebase waiting on conflicts, got \(String(describing: fixture.model.operations.conflictState))")
            return
        }
        #expect(fixture.model.gitIgnoreMenuItems(for: ["README.md"]).isEmpty)
        #expect(!EspalierCore.gitIgnoreMenuItems(for: ["README.md"]).isEmpty)
    }
}

/// The paths of the changes list, in its order.
@MainActor
private func changedPaths(_ fixture: SelectedRepository) -> [String] {
    fixture.model.changes.workingDirectory.files.map(\.path)
}

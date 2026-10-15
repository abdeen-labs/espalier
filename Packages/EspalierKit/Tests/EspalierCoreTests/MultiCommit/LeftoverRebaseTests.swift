// Which rebase state is one Espalier can't continue or abort, and clearing
// it: never a rebase Espalier shows, never `git am`'s.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Leftover rebase state", .offline) @MainActor
struct LeftoverRebaseTests {
    /// What's in the git directory, by path relative to it (a trailing `/`
    /// makes a directory; `HEAD` stands for HEAD's commit), and the leftover
    /// it is, if any.
    struct StateCase: Sendable {
        let files: [String: String]
        let leftover: LeftoverRebase?
    }

    nonisolated static let states: [NamedCase<StateCase>] = [
        NamedCase("no rebase state", StateCase(files: [:], leftover: nil)),
        NamedCase("an empty rebase-merge", StateCase(files: ["rebase-merge/": ""], leftover: LeftoverRebase(hasAutostash: false))),
        NamedCase("rebase-merge with an autostash and nothing else", StateCase(
            files: ["rebase-merge/autostash": "HEAD"], leftover: LeftoverRebase(hasAutostash: true)
        )),
        NamedCase("rebase-merge missing onto, with REBASE_HEAD", StateCase(
            files: ["rebase-merge/head-name": "refs/heads/main", "rebase-merge/orig-head": "HEAD", "REBASE_HEAD": "HEAD"],
            leftover: LeftoverRebase(hasAutostash: false)
        )),
        NamedCase("an empty rebase-apply", StateCase(files: ["rebase-apply/": ""], leftover: LeftoverRebase(hasAutostash: false))),
        NamedCase("git am's rebase-apply", StateCase(files: ["rebase-apply/applying": "", "rebase-apply/next": "1"], leftover: nil)),
        NamedCase("a rebase interrupted between commits", StateCase(
            files: ["rebase-merge/head-name": "refs/heads/main", "rebase-merge/orig-head": "HEAD", "rebase-merge/onto": "HEAD"],
            leftover: nil
        )),
        NamedCase("a stopped rebase", StateCase(
            files: [
                "rebase-merge/head-name": "refs/heads/main", "rebase-merge/orig-head": "HEAD", "rebase-merge/onto": "HEAD",
                "REBASE_HEAD": "HEAD",
            ],
            leftover: nil
        )),
    ]

    @Test("is a rebase state directory Espalier shows no rebase for, and not git am's", arguments: states)
    func detection(_ state: NamedCase<StateCase>) async throws {
        let repository = try setupEmptyRepository("main")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "readme\n")], commitMessage: "First"))
        let head = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        for (name, contents) in state.value.files {
            let path = POSIXPath.join(repository.resolvedGitDir, name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
            try Data(((contents == "HEAD" ? head : contents) + "\n").utf8).write(to: URL(filePath: path))
        }
        #expect(await getLeftoverRebase(repository) == state.value.leftover)
    }

    /// `main` with a commit that conflicts with `other`'s.
    private func conflictingRepository() async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "other"], local)
            try await commitFile(local, "README.md", "other\n", message: "Other")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "README.md", "main\n", message: "Main")
        }
    }

    @Test("clearing refuses a rebase Espalier shows, and leaves it as it is")
    func refusesShownRebase() async throws {
        let fixture = try await conflictingRepository()
        try #require(try await runGitAllowingFailure(["rebase", "other"], fixture.local) != 0)
        try #require(fixture.gitFileExists("REBASE_HEAD"))
        let state = await getRebaseInternalState(fixture.local)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.clearLeftoverRebase()
        }
        #expect(preconditionText(error) != nil)
        #expect(await getRebaseInternalState(fixture.local) == state)
        #expect(fixture.gitFileExists("rebase-merge/git-rebase-todo"))
        await fixture.app.idle()
    }

    @Test("clearing leaves git am's directory alone, with git's refusal")
    func refusesGitAm() async throws {
        let fixture = try await conflictingRepository()
        let patch = try await runGit(["format-patch", "-1", "--stdout", "other"], fixture.local)
        let am = try await Dugite.exec(["am"], fixture.local.path, options: Dugite.ExecutionOptions(stdin: Data(patch.utf8)))
        try #require(am.exitCode != 0)
        try #require(fixture.gitFileExists("rebase-apply/applying"))

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.clearLeftoverRebase()
        }
        #expect(error?.gitFailure?.gitError == .applyingPatchesInProgress)
        #expect(fixture.gitFileExists("rebase-apply/applying"))
        await fixture.app.idle()
    }

    @Test("clearing with nothing left to clear does nothing")
    func nothingToClear() async throws {
        let fixture = try await conflictingRepository()
        let head = try await fixture.head()
        try await fixture.model.operations.clearLeftoverRebase()
        #expect(try await fixture.head() == head)
        #expect(try await runGit(["status", "--porcelain"], fixture.local).isEmpty)
        await fixture.app.idle()
    }
}

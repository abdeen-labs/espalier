// All Work: the base and merge base it compares the branch with, the files
// it lists (renames, deletions, untracked and binary files, a file changed
// again uncommitted, one reverted uncommitted), their diffs from the merge
// base to the working tree, when it's available (an operation waiting on
// conflicts, a detached HEAD, an unborn branch, no base), the scope ending
// with the worktree and the repository's selection, and the viewed marks (clearing as a file changes,
// persisting, pruning). Against real git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("All Work", .offline, .hangGuard(minutes: 5))
@MainActor
struct AllWorkTests {
    /// A clone of `origin` on `feature`, which branches from `main` (one
    /// commit, README.md) and adds `count` commits.
    private func featureBranch(commits: [(path: String, contents: String)]) async throws -> ChangesFixture {
        let (local, _) = try await setupRepositoryWithRemote()
        try await runGit(["checkout", "-b", "feature"], local)
        for (index, commit) in commits.enumerated() {
            try write(commit.path, commit.contents, in: local)
            try await runGit(["add", "--", literalPathspec(commit.path)], local)
            try await runGit(["commit", "-m", "Commit \(index + 1)"], local)
        }
        return try await ChangesFixture.make(local)
    }

    private func write(_ path: String, _ contents: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(exactFilePath: fullPath))
    }

    /// Chooses All Work and waits for its files.
    private func showAllWork(_ fixture: ChangesFixture) async {
        fixture.model.allWork.choose(.allWork)
        await fixture.settle()
    }

    private func file(_ fixture: ChangesFixture, _ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> AllWorkFile {
        try #require(fixture.model.allWork.files.first { $0.path == path }, "No All Work file \(path)", sourceLocation: sourceLocation)
    }

    private func diffLines(_ fixture: ChangesFixture, _ path: String) async throws -> [String] {
        let allWork = fixture.model.allWork
        allWork.select(try file(fixture, path).id)
        await allWork.idle()
        let text = try #require(textDiffData(allWork.diff.value), "No text diff for \(path)")
        return text.hunks.flatMap(\.lines).filter { $0.type == .add || $0.type == .delete }.map(\.content)
    }

    // MARK: The base

    @Test("a branch compares with the default branch from their merge base: the default branch's later commits aren't its work")
    func baseAndMergeBase() async throws {
        let fixture = try await featureBranch(commits: [("a.txt", "a\n"), ("b.txt", "b\n")])
        let mergeBase = JSCompat.trim(try await fixture.git(["rev-parse", "main"]))
        // main moves on after the branch left it.
        try await fixture.git(["checkout", "main"])
        try fixture.write("main-only.txt", "main\n")
        try await fixture.git(["add", "main-only.txt"])
        try await fixture.git(["commit", "-m", "Main moves on"])
        try await fixture.git(["checkout", "feature"])
        await fixture.refresh(.full)
        await showAllWork(fixture)

        let allWork = fixture.model.allWork
        #expect(allWork.comparison == AllWorkComparison(baseName: "main", mergeBase: mergeBase, commitCount: 2))
        #expect(allWork.isAvailable)
        #expect(allWork.scope == .allWork)
        #expect(allWork.files.map(\.path) == ["a.txt", "b.txt"])
    }

    @Test("on the default branch, the base is its upstream: unpushed commits are its work, and none leaves All Work unavailable")
    func defaultBranchUsesUpstream() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        fixture.model.allWork.choose(.allWork)
        await fixture.settle()
        let allWork = fixture.model.allWork
        #expect(allWork.comparison?.baseName == "origin/main")
        #expect(allWork.comparison?.commitCount == 0)
        #expect(!allWork.isAvailable)
        #expect(allWork.scope == .uncommitted)

        try fixture.write("local.txt", "local\n")
        try await fixture.git(["add", "local.txt"])
        try await fixture.git(["commit", "-m", "Local commit"])
        await fixture.refresh(.full)
        #expect(allWork.comparison?.commitCount == 1)
        #expect(allWork.scope == .allWork)
        #expect(allWork.files.map(\.path) == ["local.txt"])
    }

    @Test("a detached HEAD, an unborn branch, and a branch with no base have no comparison")
    func noComparison() async throws {
        // Detached.
        let detached = try await featureBranch(commits: [("a.txt", "a\n")])
        try await detached.git(["checkout", "--detach"])
        await detached.refresh(.full)
        await showAllWork(detached)
        #expect(detached.model.allWork.comparison == nil)
        #expect(detached.model.allWork.scope == .uncommitted)

        // Unborn.
        let unborn = try await ChangesFixture.make(try setupEmptyRepositoryDefaultMain())
        try unborn.write("new.txt", "new\n")
        await unborn.refresh()
        await showAllWork(unborn)
        #expect(unborn.model.allWork.comparison == nil)
        #expect(unborn.model.allWork.scope == .uncommitted)

        // No remote and no default branch: only `feature`.
        let lone = try setupEmptyRepository("feature")
        try write("a.txt", "a\n", in: lone)
        try await runGit(["add", "a.txt"], lone)
        try await runGit(["commit", "-m", "First"], lone)
        let noBase = try await ChangesFixture.make(lone)
        await showAllWork(noBase)
        #expect(noBase.model.allWork.comparison == nil)
        #expect(noBase.model.allWork.files.isEmpty)
        #expect(noBase.model.allWork.scope == .uncommitted)
    }

    @Test("while a merge waits on its conflicts, Changes shows Uncommitted")
    func conflictsShowUncommitted() async throws {
        let fixture = try await featureBranch(commits: [("README.md", "# Feature\n")])
        try await fixture.git(["checkout", "-b", "other", "main"])
        try fixture.write("README.md", "# Other\n")
        try await fixture.git(["commit", "-am", "Other"])
        try await fixture.git(["checkout", "feature"])
        await fixture.refresh(.full)
        await showAllWork(fixture)
        #expect(fixture.model.allWork.scope == .allWork)

        _ = try await Dugite.exec(["merge", "other"], fixture.local.path)
        await fixture.refresh(.full)
        #expect(fixture.model.gitState.inProgress != nil)
        #expect(!fixture.model.allWork.isAvailable)
        #expect(fixture.model.allWork.scope == .uncommitted)
        // The choice stays for when the merge ends.
        #expect(fixture.model.allWork.chosenScope == .allWork)
    }

    // MARK: The files

    @Test("the list holds renames, deletions, untracked and binary files, a file changed again uncommitted, and leaves out one reverted uncommitted")
    func files() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try write("old-name.txt", "one\ntwo\nthree\nfour\nfive\n", in: local)
        try write("gone.txt", "gone\n", in: local)
        try write("reverted.txt", "same\n", in: local)
        try await runGit(["add", "."], local)
        try await runGit(["commit", "-m", "Files on main"], local)
        try await runGit(["push", "origin", "main"], local)
        try await runGit(["checkout", "-b", "feature"], local)
        try await runGit(["mv", "old-name.txt", "new-name.txt"], local)
        try await runGit(["rm", "-q", "gone.txt"], local)
        try write("reverted.txt", "changed\n", in: local)
        try write("both.txt", "committed\n", in: local)
        try Data([0x89, 0x50, 0x00, 0x01, 0x02, 0x00]).write(to: URL(exactFilePath: POSIXPath.join(local.path, "data.bin")))
        try await runGit(["add", "."], local)
        try await runGit(["commit", "-m", "Branch work"], local)
        // Uncommitted: both.txt again, reverted.txt back as on main, and an
        // untracked file.
        try write("both.txt", "committed\nagain\n", in: local)
        try write("reverted.txt", "same\n", in: local)
        try write("untracked.txt", "new\n", in: local)
        let fixture = try await ChangesFixture.make(local)
        await showAllWork(fixture)

        let allWork = fixture.model.allWork
        #expect(allWork.files.map(\.path) == ["both.txt", "data.bin", "gone.txt", "new-name.txt", "untracked.txt"])
        let renamed = try file(fixture, "new-name.txt")
        #expect(renamed.change.status.kind == .renamed)
        #expect(renamed.change.status.oldPath == "old-name.txt")
        #expect(try file(fixture, "gone.txt").change.status.kind == .deleted)
        #expect(try file(fixture, "gone.txt").contentID == deletedContentID)
        #expect(try file(fixture, "untracked.txt").change.status.kind == .untracked)
        #expect(try file(fixture, "data.bin").lineCount == FileLineCount(added: nil, deleted: nil))
        // Counted from the merge base: the commit's line and the
        // uncommitted one.
        let both = try file(fixture, "both.txt")
        #expect(allWork.lineCount(both) == FileLineCount(added: 2, deleted: 0))
        let uncommitted = allWork.uncommittedPaths
        #expect(allWork.isUncommitted(both, in: uncommitted))
        #expect(!allWork.isUncommitted(renamed, in: uncommitted))
        #expect(allWork.isUncommitted(try file(fixture, "untracked.txt"), in: uncommitted))
        // The untracked file's count is Changes'.
        #expect(allWork.lineCount(try file(fixture, "untracked.txt")) == FileLineCount(added: 1, deleted: 0))
    }

    @Test("each file's diff runs from the merge base to the working tree")
    func diffs() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try write("gone.txt", "gone\n", in: local)
        try await runGit(["add", "."], local)
        try await runGit(["commit", "-m", "Files on main"], local)
        try await runGit(["push", "origin", "main"], local)
        try await runGit(["checkout", "-b", "feature"], local)
        try write("README.md", "# README\ncommitted\n", in: local)
        try await runGit(["rm", "-q", "gone.txt"], local)
        try Data([0x00, 0x01]).write(to: URL(exactFilePath: POSIXPath.join(local.path, "data.bin")))
        try await runGit(["add", "."], local)
        try await runGit(["commit", "-m", "Branch work"], local)
        try write("README.md", "# README\ncommitted\nuncommitted\n", in: local)
        try write("untracked.txt", "new\n", in: local)
        let fixture = try await ChangesFixture.make(local)
        await showAllWork(fixture)

        #expect(try await diffLines(fixture, "README.md") == ["committed", "uncommitted"])
        #expect(try await diffLines(fixture, "gone.txt") == ["gone"])
        #expect(try await diffLines(fixture, "untracked.txt") == ["new"])
        let allWork = fixture.model.allWork
        allWork.select(try file(fixture, "data.bin").id)
        await allWork.idle()
        #expect(allWork.diff.value == .binary)
    }

    @Test("a file whose name is a pathspec pattern lists and diffs only itself", arguments: PatternPath.representative)
    func patternPaths(_ pattern: PatternPath) async throws {
        let fixture = try await featureBranch(commits: [(pattern.name, "pattern\n"), (pattern.decoy, "decoy\n")])
        await showAllWork(fixture)
        #expect(try await diffLines(fixture, pattern.name) == ["pattern"])
    }

    // MARK: The scope

    @Test("Changes starts in Uncommitted, and All Work ends when the worktree changes or another repository is selected")
    func scopeEnds() async throws {
        let fixture = try await featureBranch(commits: [("a.txt", "a\n")])
        let allWork = fixture.model.allWork
        #expect(allWork.chosenScope == .uncommitted)
        #expect(allWork.scope == .uncommitted)
        #expect(allWork.files.isEmpty)

        await showAllWork(fixture)
        #expect(allWork.scope == .allWork)
        allWork.select(try file(fixture, "a.txt").id)
        // As when the repository opens at another worktree.
        allWork.repositoryPathDidChange(keepingSharedState: true)
        #expect(allWork.chosenScope == .uncommitted)
        #expect(allWork.files.isEmpty)
        #expect(allWork.selectedFileID == nil)

        await showAllWork(fixture)
        #expect(allWork.scope == .allWork)
        allWork.select(try file(fixture, "a.txt").id)
        allWork.repositoryDidBecomeInactive()
        #expect(allWork.chosenScope == .uncommitted)
        #expect(allWork.files.isEmpty)
        #expect(allWork.selectedFileID == nil)
    }

    // MARK: Viewed marks

    @Test("a mark clears when its file changes, the next unviewed file follows, marks persist, and marks of files no longer listed are dropped")
    func viewedMarks() async throws {
        let fixture = try await featureBranch(commits: [("a.txt", "a\n"), ("b.txt", "b\n"), ("c.txt", "c\n")])
        await showAllWork(fixture)
        let allWork = fixture.model.allWork

        // Marking the selected file selects the next one not viewed.
        allWork.select(try file(fixture, "a.txt").id)
        allWork.setViewed(try file(fixture, "c.txt"), true)
        allWork.toggleSelectedViewed()
        #expect(allWork.isViewed(try file(fixture, "a.txt")))
        #expect(allWork.selectedFile?.path == "b.txt")
        #expect(allWork.viewedCount == 2)

        // Persisted, as a later launch reads them.
        await fixture.app.viewedMarks.idle()
        let saved = ViewedMarksStore.read(fixture.app.viewedMarks.fileURL)[ExactString(fixture.local.path)] ?? [:]
        #expect(Set(saved.keys) == [ExactString("a.txt"), ExactString("c.txt")])

        // a.txt changes again: its mark clears.
        try fixture.write("a.txt", "a changed\n")
        await fixture.refresh()
        #expect(!allWork.isViewed(try file(fixture, "a.txt")))
        #expect(allWork.isViewed(try file(fixture, "c.txt")))

        // c.txt leaves the list (back as on the base): its mark is dropped.
        allWork.setViewed(try file(fixture, "b.txt"), true)
        try await fixture.git(["rm", "-q", "c.txt"])
        await fixture.refresh()
        #expect(allWork.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(Set(allWork.viewedMarks.keys) == [ExactString("b.txt")])
        await fixture.app.viewedMarks.idle()
        let pruned = ViewedMarksStore.read(fixture.app.viewedMarks.fileURL)[ExactString(fixture.local.path)] ?? [:]
        #expect(Set(pruned.keys) == [ExactString("b.txt")])
    }
}

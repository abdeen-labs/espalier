// Files whose names git reads as patterns or as magic when they're
// pathspecs (`a*.txt`, `:d.txt`, `:!e.txt`), end to end through the models.
// Every write that takes paths touches only the named file: discarding it
// (whole or by lines), committing it (whole, in part, and as part of a
// rename), taking a side of its conflict or deleting it, and undoing the
// first commit. Paths passed as patterns would also change the decoy next
// to each.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: names git reads as patterns", .offline) @MainActor
struct PatternNamesTests {
    /// A selected repository on `main` with the name and its decoy
    /// committed, each holding `contents`.
    private func makeFixture(_ path: PatternPath, contents: String? = nil) async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try write(fixture, path.name, contents ?? "name\n")
        try write(fixture, path.decoy, "decoy\n")
        try await git(fixture, ["add", "-A"])
        try await git(fixture, ["commit", "-q", "-m", "Add both"])
        await fixture.refresh(.full)
        return fixture
    }

    /// Runs git in the fixture's repository, reading pathspecs literally.
    @discardableResult
    private func git(_ fixture: ChangesFixture, _ args: [String]) async throws -> String {
        try await fixture.git(["--literal-pathspecs"] + args)
    }

    private func write(_ fixture: ChangesFixture, _ path: String, _ contents: String) throws {
        try writeFileExactly(path, contents, in: fixture.local.path)
    }

    private func read(_ fixture: ChangesFixture, _ path: String) -> String? {
        readFileExactly(path, in: fixture.local.path)
    }

    /// The paths HEAD's commit changes, renames as a removal and an
    /// addition.
    private func committedPaths(_ fixture: ChangesFixture) async throws -> Set<String> {
        let output = try await git(fixture, ["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", "HEAD"])
        return Set(JSCompat.split(output, "\0").filter { !$0.isEmpty })
    }

    // MARK: Discarding

    @Test("discarding a file restores only it; the other file's staged and unstaged changes stay", arguments: PatternPath.representative)
    func discardWholeFile(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path)
        try write(fixture, path.name, "name staged\n")
        try write(fixture, path.decoy, "decoy staged\n")
        try await git(fixture, ["add", "-A"])
        try write(fixture, path.decoy, "decoy in the working directory\n")
        await fixture.refresh()

        try await fixture.changes.discard([try fixture.file(path.name)], confirmed: [.discardChanges])
        await fixture.settle()

        #expect(read(fixture, path.name) == "name\n")
        #expect(read(fixture, path.decoy) == "decoy in the working directory\n")
        #expect(try await git(fixture, ["show", ":0:\(path.decoy)"]) == "decoy staged\n")
        #expect(fixture.paths == [path.decoy])
    }

    @Test("discarding lines of a file discards only its lines", arguments: PatternPath.representative)
    func discardLines(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path, contents: numberedLines(20))
        try write(fixture, path.name, numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        try write(fixture, path.decoy, "decoy changed\n")
        await fixture.refresh()
        try await fixture.select(path.name)
        #expect(addedLines(try fixture.shownText()) == ["line two", "line fifteen"])

        try await fixture.changes.discardLines(.hunk(containing: try fixture.lineIndex(.add, "line fifteen")), confirmed: [.discardLines])
        await fixture.settle()

        #expect(read(fixture, path.name) == numberedLines(20, replacing: [2: "line two"]))
        #expect(read(fixture, path.decoy) == "decoy changed\n")
    }

    // MARK: Committing

    @Test("committing a file commits only it, whole or in part", arguments: PatternPath.representative)
    func commitFile(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path, contents: numberedLines(20))
        try write(fixture, path.name, numberedLines(20, replacing: [2: "line two"]))
        try write(fixture, path.decoy, "decoy changed\n")
        await fixture.refresh()
        try fixture.include([path.name])
        _ = try await fixture.commitIncluded("Line two")
        #expect(try await committedPaths(fixture) == [path.name])
        #expect(fixture.paths == [path.decoy])

        try write(fixture, path.name, numberedLines(20, replacing: [2: "line 2", 15: "line fifteen"]))
        await fixture.refresh()
        try await fixture.select(path.name)
        let fifteen = try fixture.lineIndex(.add, "line fifteen")
        try fixture.include([path.name])
        #expect(fixture.changes.setLines(.hunk(containing: fifteen), included: false))
        _ = try await fixture.commitIncluded("Line two again")

        #expect(try await committedPaths(fixture) == [path.name])
        #expect(try await git(fixture, ["show", "HEAD:\(path.name)"]) == numberedLines(20))
        #expect(read(fixture, path.decoy) == "decoy changed\n")
        #expect(Set(fixture.paths) == [path.name, path.decoy])
    }

    @Test("committing part of a renamed file commits only the rename", arguments: PatternPath.representative)
    func commitPartOfRename(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path, contents: numberedLines(20))
        try await git(fixture, ["mv", "--", path.name, "moved.txt"])
        try write(fixture, "moved.txt", numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        try write(fixture, path.decoy, "decoy changed\n")
        await fixture.refresh()
        #expect(try fixture.file("moved.txt").status.kind == .renamed)

        try await fixture.select("moved.txt")
        let fifteen = try fixture.lineIndex(.add, "line fifteen")
        try fixture.include(["moved.txt"])
        #expect(fixture.changes.setLines(.hunk(containing: fifteen), included: false))
        _ = try await fixture.commitIncluded("Move")

        #expect(try await committedPaths(fixture) == [path.name, "moved.txt"])
        #expect(try await git(fixture, ["show", "HEAD:moved.txt"]) == numberedLines(20, replacing: [2: "line two"]))
        #expect(read(fixture, path.decoy) == "decoy changed\n")
    }

    // MARK: Conflicts

    /// The name and its decoy changed on `feature` and, differently, on
    /// `main`, then `feature` merged: both conflict.
    private func makeConflictedFixture(_ path: PatternPath) async throws -> ChangesFixture {
        let fixture = try await makeFixture(path)
        try await git(fixture, ["checkout", "-q", "-b", "feature"])
        try write(fixture, path.name, "name theirs\n")
        try write(fixture, path.decoy, "decoy theirs\n")
        try await git(fixture, ["commit", "-qam", "Theirs"])
        try await git(fixture, ["checkout", "-q", "main"])
        try write(fixture, path.name, "name ours\n")
        try write(fixture, path.decoy, "decoy ours\n")
        try await git(fixture, ["commit", "-qam", "Ours"])
        #expect(try await fixture.gitAllowingFailure(["merge", "feature"]) != 0)
        await fixture.refresh(.full)
        #expect(Set(fixture.model.operations.unresolvedFiles.map(\.path)) == [path.name, path.decoy])
        return fixture
    }

    @Test("taking a side of a conflicted file keeps the other file's own resolution", arguments: PatternPath.representative, [ManualConflictResolution.ours, .theirs])
    func takeSide(_ path: PatternPath, resolution: ManualConflictResolution) async throws {
        let fixture = try await makeConflictedFixture(path)
        try write(fixture, path.decoy, "decoy by hand\n")
        await fixture.refresh()
        fixture.model.operations.setManualResolution(resolution, forPath: path.name)

        #expect(try await fixture.model.operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
        await fixture.settle()

        let side = resolution == .ours ? "name ours\n" : "name theirs\n"
        #expect(try await git(fixture, ["show", "HEAD:\(path.name)"]) == side)
        #expect(try await git(fixture, ["show", "HEAD:\(path.decoy)"]) == "decoy by hand\n")
        #expect(read(fixture, path.decoy) == "decoy by hand\n")
        #expect(fixture.paths.isEmpty)
    }

    @Test("taking the side that deleted a conflicted file deletes only it", arguments: PatternPath.representative)
    func takeDeletingSide(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path)
        try await git(fixture, ["checkout", "-q", "-b", "feature"])
        try await git(fixture, ["rm", "-q", "--", path.name])
        try await git(fixture, ["commit", "-q", "-m", "Delete the name"])
        try await git(fixture, ["checkout", "-q", "main"])
        try write(fixture, path.name, "name ours\n")
        try await git(fixture, ["commit", "-qam", "Change the name"])
        #expect(try await fixture.gitAllowingFailure(["merge", "feature"]) != 0)
        await fixture.refresh(.full)
        #expect(fixture.model.operations.unresolvedFiles.map(\.path) == [path.name])
        fixture.model.operations.setManualResolution(.theirs, forPath: path.name)

        #expect(try await fixture.model.operations.continueOperation() == .merge(.merged(ours: "main", theirs: "feature")))
        await fixture.settle()

        let tree = try await git(fixture, ["ls-tree", "-r", "-z", "--name-only", "HEAD"])
        #expect(Set(JSCompat.split(tree, "\0").filter { !$0.isEmpty }) == ["README.md", path.decoy])
        #expect(read(fixture, path.name) == nil)
        #expect(read(fixture, path.decoy) == "decoy\n")
        #expect(fixture.paths.isEmpty)
    }

    // MARK: Restoring a stash

    @Test("a stash restore that conflicted on the file is dropped once its resolution is committed", arguments: PatternPath.representative)
    func conflictedRestoreSettles(_ path: PatternPath) async throws {
        let fixture = try await makeFixture(path)
        try write(fixture, path.name, "name stashed\n")
        await fixture.refresh()
        #expect(try await fixture.stash.stashAllChanges())
        await fixture.settle()
        try write(fixture, path.name, "name committed\n")
        try await git(fixture, ["commit", "-qam", "Change the name"])
        await fixture.refresh(.full)
        let entry = try #require(fixture.stash.current)
        try await fixture.stash.restore(entry)
        await fixture.settle()
        #expect(fixture.stash.conflictedRestore?.paths == [path.name])

        try write(fixture, path.name, "name resolved\n")
        await fixture.refresh()
        fixture.commit.draft.summary = "Resolve the name"
        _ = try await fixture.commit.commit()
        await fixture.settle()

        #expect(fixture.stash.conflictedRestore == nil)
        #expect(try await fixture.stashList().isEmpty)
        #expect(read(fixture, path.decoy) == "decoy\n")
    }

    // MARK: Undoing the first commit

    @Test("undoing the first commit restores only the file deleted since; the other file keeps its edits", arguments: PatternPath.representative)
    func undoFirstCommit(_ path: PatternPath) async throws {
        let local = try setupEmptyRepositoryDefaultMain()
        try writeFileExactly(path.name, "name\n", in: local.path)
        try writeFileExactly(path.decoy, "decoy\n", in: local.path)
        try await runGit(["add", "-A"], local)
        try await runGit(["commit", "-q", "-m", "Initial"], local)
        let fixture = try await ChangesFixture.make(local)

        try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, path.name))
        try write(fixture, path.decoy, "decoy edited\n")
        await fixture.refresh()
        let commit = try #require(try await getCommit(local, try await fixture.head()))
        try await fixture.commit.undo(commit, confirmed: [.undoCommitWithChanges])
        await fixture.settle()

        #expect(fixture.gitState.tip == .unborn(ref: "main"))
        #expect(read(fixture, path.name) == "name\n")
        #expect(read(fixture, path.decoy) == "decoy edited\n")
        #expect(Set(fixture.paths) == [path.name, path.decoy])
    }
}

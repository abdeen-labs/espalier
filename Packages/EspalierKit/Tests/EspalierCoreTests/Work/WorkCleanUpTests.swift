// These drive `AppModel.cleanUp` against local bare remotes: removing a
// merged branch's linked worktree and branch, in a selected repository and
// one that isn't, also when squash-merged (not an ancestor of the default
// branch); a worktree whose folder is gone; a record pointing at the
// worktree; the main worktree on the merged branch; each refusal, with
// nothing changed; declining; and folder and file names git reads as
// patterns.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Home: Clean Up", .offline) @MainActor
struct WorkCleanUpTests {
    /// Every confirmation Clean Up asks for.
    private let allConfirmed: Set<ConfirmationKind> = [.cleanUpWorktree, .cleanUpMissingWorktree, .cleanUpBranch]

    /// A fixture whose `feature`, published, is checked out in a linked
    /// worktree named `folder`: its pull request "merged" at its tip.
    private func makeMergedWorktree(
        selected: Bool,
        folder: String = "feature-tree"
    ) async throws -> (fixture: WorkFixture, path: String, request: CleanUpRequest) {
        var tip = ""
        let fixture = try await WorkFixture.make(selected: selected) { local in
            tip = try await makePublishedBranch("feature", in: local)
        }
        let path = try await fixture.addWorktree(folder, branch: "feature")
        return (fixture, path, CleanUpRequest(worktree: fixture.key(path), branch: "feature", mergedCommit: tip))
    }

    /// The confirmation `cleanUp` asks for, failing the test without one.
    private func confirmation(_ app: AppModel, _ request: CleanUpRequest) async -> EspalierCore.Confirmation? {
        let error = await #expect(throws: OperationError.self) {
            try await app.cleanUp(request)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return nil
        }
        return confirmation
    }

    /// Whether `branch` is a local branch of `repository`.
    private func hasBranch(_ branch: String, _ repository: Repository) async throws -> Bool {
        try await resolveRef("refs/heads/\(branch)", in: repository) != nil
    }

    // MARK: Linked worktrees

    @Test("asks first, then removes a linked worktree and its branch in any repository, leaving the remote branch and the selection", arguments: [false, true])
    func removesLinkedWorktree(selected: Bool) async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: selected)
        let selection = fixture.app.selection
        let recordPath = fixture.model.record.path

        let asked = await confirmation(fixture.app, request)
        #expect(asked?.kind == .cleanUpWorktree)
        #expect(asked?.details == .cleanUp(branch: "feature", folder: realPath(path)))
        // Declining is not calling again: nothing changed.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await hasBranch("feature", fixture.local))

        let outcome = try await fixture.app.cleanUp(request, confirmed: [.cleanUpWorktree])

        #expect(outcome == .removedWorktree)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await fixture.worktreePaths() == [realPath(fixture.local.path)])
        #expect(try await !hasBranch("feature", fixture.local))
        #expect(try await fixture.remoteTip("feature") == request.mergedCommit)
        #expect(fixture.model.record.path == recordPath)
        #expect(fixture.app.selection == selection)
        await fixture.app.idle()
    }

    @Test("deletes a squash-merged branch, which isn't an ancestor of the default branch")
    func removesSquashMergedBranch() async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: false)
        // The pull request squashed into one new commit on main.
        try await runGit(["merge", "-q", "--squash", "feature"], fixture.local)
        try await runGit(["commit", "-q", "-m", "Feature (#1)"], fixture.local)
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        #expect(try await runGitAllowingFailure(["merge-base", "--is-ancestor", "feature", "main"], fixture.local) == 1)

        try await fixture.app.cleanUp(request, confirmed: [.cleanUpWorktree])

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await !hasBranch("feature", fixture.local))
        await fixture.app.idle()
    }

    @Test("a worktree whose folder is gone is removed from git's list, and its branch deleted")
    func removesMissingWorktree() async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: false)
        try FileManager.default.removeItem(atPath: path)

        let asked = await confirmation(fixture.app, request)
        #expect(asked?.kind == .cleanUpMissingWorktree)

        try await fixture.app.cleanUp(request, confirmed: [.cleanUpMissingWorktree])

        #expect(try await fixture.worktreePaths() == [realPath(fixture.local.path)])
        #expect(try await !hasBranch("feature", fixture.local))
        await fixture.app.idle()
    }

    @Test("agreeing to remove a missing worktree removes nothing once its folder is back: it asks again")
    func missingWorktreeBackAsksAgain() async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: false)
        let moved = path + "-moved"
        try FileManager.default.moveItem(atPath: path, toPath: moved)
        #expect(await confirmation(fixture.app, request)?.kind == .cleanUpMissingWorktree)
        try FileManager.default.moveItem(atPath: moved, toPath: path)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.app.cleanUp(request, confirmed: [.cleanUpMissingWorktree])
        }

        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .cleanUpWorktree)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await hasBranch("feature", fixture.local))
        await fixture.app.idle()
    }

    @Test("a record pointing at the worktree moves to the main worktree, selected only if it was", arguments: [false, true])
    func recordAtWorktreeMovesToMain(selected: Bool) async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let tip = try await makePublishedBranch("feature", in: local)
        let directory = try createTempDirectory(prefix: "espalier-work-")
        let path = POSIXPath.join(directory, "feature-tree")
        try await runGit(["worktree", "add", "-q", path, "feature"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model: RepositoryModel
        if selected {
            model = try await harness.addAndSelect(Repository(path: path), to: app)
        } else {
            model = try await WorkFixture.add(path, to: app)
        }
        let request = CleanUpRequest(worktree: WorktreeKey(repositoryID: model.id, path: path), branch: "feature", mergedCommit: tip)

        try await app.cleanUp(request, confirmed: [.cleanUpWorktree])

        #expect(realPath(model.record.path) == realPath(local.path))
        #expect(!model.record.isMissing)
        #expect(app.selection == (selected ? .repository(model.id) : nil))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await !hasBranch("feature", local))
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "main")
    }

    // MARK: The main worktree

    @Test("the main worktree on the merged branch checks out the default branch, without pulling, and deletes the branch", arguments: [false, true])
    func mainWorktree(selected: Bool) async throws {
        var tip = ""
        let fixture = try await WorkFixture.make(selected: selected) { local in
            tip = try await makePublishedBranch("feature", in: local)
            try await runGit(["checkout", "-q", "feature"], local)
        }
        let localMain = try await fixture.localSHA("refs/heads/main")
        try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        let request = CleanUpRequest(worktree: fixture.key(fixture.local.path), branch: "feature", mergedCommit: tip)

        let asked = await confirmation(fixture.app, request)
        #expect(asked?.kind == .cleanUpBranch)
        #expect(asked?.details == .cleanUp(branch: "feature", folder: nil))
        #expect(try await symbolicRef("HEAD", in: fixture.local) == "refs/heads/feature")

        let outcome = try await fixture.app.cleanUp(request, confirmed: [.cleanUpBranch])

        #expect(outcome == .checkedOutDefaultBranch("main"))
        #expect(try await symbolicRef("HEAD", in: fixture.local) == "refs/heads/main")
        #expect(try await fixture.localSHA("refs/heads/main") == localMain)
        #expect(try await !hasBranch("feature", fixture.local))
        #expect(try await fixture.remoteTip("feature") == tip)
        await fixture.app.idle()
        if selected {
            #expect(fixture.model.gitState.tip.branch?.name == "main")
        }
    }

    @Test("the main worktree checks out a default branch only the remote has as a local branch tracking it")
    func mainWorktreeRemoteDefaultBranch() async throws {
        var tip = ""
        let fixture = try await WorkFixture.make(selected: true) { local in
            tip = try await makePublishedBranch("feature", in: local)
            try await runGit(["checkout", "-q", "feature"], local)
            try await runGit(["branch", "-q", "-D", "main"], local)
        }
        let request = CleanUpRequest(worktree: fixture.key(fixture.local.path), branch: "feature", mergedCommit: tip)

        try await fixture.app.cleanUp(request, confirmed: [.cleanUpBranch])

        #expect(try await symbolicRef("HEAD", in: fixture.local) == "refs/heads/main")
        #expect(JSCompat.trim(try await runGit(["rev-parse", "--abbrev-ref", "main@{upstream}"], fixture.local)) == "origin/main")
        #expect(try await !hasBranch("feature", fixture.local))
        await fixture.app.idle()
    }

    // MARK: Refusals

    /// What keeps a merged branch from being cleaned up.
    enum Refusal: String, CaseIterable, CustomTestStringConvertible {
        case tipMoved, trackedChange, untrackedFile, locked, notOnBranch, alsoCheckedOut, defaultBranch, noDefaultBranch, mergeInProgress

        var testDescription: String {
            rawValue
        }
    }

    @Test("refuses, with nothing removed, when a check fails in the lane", arguments: Refusal.allCases)
    func refuses(_ refusal: Refusal) async throws {
        let made = try await makeMergedWorktree(selected: false)
        let fixture = made.fixture
        var path = made.path
        var request = made.request
        let worktree = Repository(path: path)
        switch refusal {
        case .tipMoved:
            try await commitFile(worktree, "after.txt", "after the merge\n")
        case .trackedChange:
            try Data("changed\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "feature.txt")))
        case .untrackedFile:
            try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "new.txt")))
        case .locked:
            try await runGit(["worktree", "lock", path], fixture.local)
        case .notOnBranch:
            // Another branch at the same commit.
            try await runGit(["checkout", "-q", "-b", "other"], worktree)
        case .alsoCheckedOut:
            try await runGit(["worktree", "add", "-q", "--force", POSIXPath.join(fixture.directory, "second"), "feature"], fixture.local)
        case .defaultBranch:
            path = fixture.local.path
            request = CleanUpRequest(worktree: fixture.key(path), branch: "main", mergedCommit: try #require(try await fixture.localSHA("main")))
        case .noDefaultBranch:
            try await runGit(["remote", "set-head", "origin", "-d"], fixture.local)
            try await runGit(["branch", "-q", "-m", "main", "trunk"], fixture.local)
        case .mergeInProgress:
            // A merge that stopped before committing, with nothing changed.
            try await commitFile(fixture.local, "main.txt", "main\n")
            try await runGit(["merge", "-q", "--no-commit", "-s", "ours", "main"], worktree)
        }
        let worktreesBefore = try await fixture.worktreePaths()
        let branchTip = try await fixture.localSHA("refs/heads/\(request.branch)")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.app.cleanUp(request, confirmed: allConfirmed)
        }

        #expect(preconditionMessage(error) != nil, "\(String(describing: error))")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await fixture.worktreePaths() == worktreesBefore)
        #expect(try await fixture.localSHA("refs/heads/\(request.branch)") == branchTip)
        await fixture.app.idle()
    }

    // MARK: Names git reads as patterns

    @Test("a worktree folder and an untracked file named like pathspecs: the file refuses, then only that folder goes", arguments: PatternPath.representative)
    func patternNames(_ name: PatternPath) async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: false, folder: name.name)
        let decoy = POSIXPath.join(fixture.directory, name.decoy)
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: false)
        try writeFileExactly(name.name, "untracked\n", in: path)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.app.cleanUp(request, confirmed: allConfirmed)
        }
        #expect(preconditionMessage(error) != nil)
        #expect(FileManager.default.fileExists(atPath: path))

        try FileManager.default.removeItem(atPath: POSIXPath.join(path, name.name))
        try await fixture.app.cleanUp(request, confirmed: allConfirmed)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: decoy))
        #expect(try await !hasBranch("feature", fixture.local))
        await fixture.app.idle()
    }

    @Test("a branch that shares its name with a tag: the branch goes, the tag stays")
    func branchSharingTagName() async throws {
        let (fixture, path, request) = try await makeMergedWorktree(selected: false)
        try await runGit(["tag", "feature", "main"], fixture.local)

        try await fixture.app.cleanUp(request, confirmed: allConfirmed)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await !hasBranch("feature", fixture.local))
        #expect(try await resolveRef("refs/tags/feature", in: fixture.local) != nil)
        await fixture.app.idle()
    }
}

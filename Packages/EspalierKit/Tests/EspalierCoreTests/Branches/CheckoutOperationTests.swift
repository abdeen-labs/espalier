// These drive `BranchesModel.checkout` against real git, with every
// strategy, the confirmations and decisions, a branch in another worktree
// or in one whose folder is gone, and the local-changes-overwritten
// recovery.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// README.md on `main`; `feature` changes its first line and adds
/// feature.txt.
private let mainReadme = (1...8).map { "line \($0)" }.joined(separator: "\n") + "\n"
private let featureReadme = mainReadme.replacingOccurrences(of: "line 1\n", with: "line one\n")

@Suite("Checkout", .offline, .hangGuard(minutes: 5)) @MainActor
struct CheckoutOperationTests {
    /// A selected repository on `main` with a `feature` branch.
    private func makeRepository(
        responder: PromptCenter.Responder? = PromptResponder.failing()
    ) async throws -> (AppHarness, AppModel, RepositoryModel, Repository) {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data(mainReadme.utf8).write(to: URL(filePath: local.path + "/README.md"))
        try await runGit(["commit", "-am", "Number the lines"], local)
        try await runGit(["checkout", "-b", "feature"], local)
        try Data(featureReadme.utf8).write(to: URL(filePath: local.path + "/README.md"))
        try Data("feature\n".utf8).write(to: URL(filePath: local.path + "/feature.txt"))
        try await runGit(["add", "."], local)
        try await runGit(["commit", "-m", "Feature"], local)
        try await runGit(["checkout", "main"], local)

        let harness = try AppHarness(responder: responder)
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        return (harness, app, repository, local)
    }

    private func branch(_ name: String, in repository: RepositoryModel) throws -> Branch {
        try #require(repository.gitState.branches.all.first { $0.name == name })
    }

    private func read(_ path: String, in local: Repository) throws -> String {
        try String(contentsOfFile: POSIXPath.join(local.path, path), encoding: .utf8)
    }

    private func stashList(_ local: Repository) async throws -> [String] {
        let output = try await runGit(["stash", "list", "--format=%gs"], local)
        return output.split(separator: "\n").map(String.init)
    }

    @Test("does nothing for the branch already checked out")
    func alreadyCheckedOut() async throws {
        let (_, app, repository, _) = try await makeRepository()
        let passes = repository.refreshScheduler.passCount
        #expect(try await repository.branches.checkout(try branch("main", in: repository)) == .alreadyCheckedOut)
        #expect(repository.refreshScheduler.passCount == passes)
        await app.idle()
    }

    @Test("checks out a branch and returns after the refresh")
    func checksOut() async throws {
        let (_, app, repository, local) = try await makeRepository()
        let feature = try branch("feature", in: repository)
        repository.history.select(shas: ["abc"], contiguous: true)
        #expect(try await repository.branches.checkout(feature) == .checkedOut(feature))
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(repository.gitState.tip.branch?.tip.sha == feature.tip.sha)
        #expect(try read("README.md", in: local) == featureReadme)
        #expect(repository.history.mode == .history)
        #expect(repository.refreshScheduler.lastPassReasons.contains(.operation(.checkoutBranch)))
        await app.idle()
    }

    @Test("asks what to do with changes under the ask strategy")
    func decision() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(try branch("feature", in: repository))
        }
        #expect(error?.reason == .decisionRequired(.uncommittedChanges(currentBranch: "main", targetBranch: "feature")))
        guard case .decisionRequired(let decision)? = error?.reason else {
            return
        }
        #expect(decision.choices.map(\.strategy) == [.stashOnCurrentBranch, .moveToNewBranch])
        #expect(repository.gitState.tip.branch?.name == "main")
        await app.idle()
    }

    @Test("leaves changes on the current branch in its stash")
    func leaveChanges() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("notes.txt", "notes\n", in: local)
        try harness.write("README.md", mainReadme + "local\n", in: local)
        await repository.refresh(.status, reason: .user)

        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature, strategy: .stashOnCurrentBranch) == .checkedOut(feature))
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(repository.changes.workingDirectory.files.isEmpty)
        #expect(try read("README.md", in: local) == featureReadme)
        #expect(try await stashList(local) == ["On main: !!Espalier<main>"])
        #expect(repository.gitState.stashes.entries(onBranch: "main").count == 1)
        #expect(repository.stash.current == nil)

        // Back on main, the stash is the branch's.
        #expect(try await repository.branches.checkout(try branch("main", in: repository)) == .checkedOut(try branch("main", in: repository)))
        #expect(repository.stash.current?.branchName == "main")
        await app.idle()
    }

    @Test("leaving changes on a branch that has a stash adds another entry, asking nothing")
    func leaveChangesBesideStash() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("first.txt", "first\n", in: local)
        await repository.refresh(.status, reason: .user)
        #expect(try await repository.stash.stashAllChanges())
        await repository.refresh(.full, reason: .user)
        let first = try #require(repository.stash.current)

        try harness.write("second.txt", "second\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature, strategy: .stashOnCurrentBranch) == .checkedOut(feature))
        #expect(try await stashList(local) == ["On main: !!Espalier<main>", "On main: !!Espalier<main>"])
        #expect(try await runGit(["stash", "show", "--name-only", "stash@{0}"], local) == "second.txt\n")
        #expect(try await runGit(["stash", "show", "--name-only", "stash@{1}"], local) == "first.txt\n")

        // Back on main, the newest is the branch's current one.
        let main = try branch("main", in: repository)
        #expect(try await repository.branches.checkout(main) == .checkedOut(main))
        #expect(repository.stash.currentEntries.count == 2)
        #expect(repository.stash.currentEntries.last?.stashSha == first.stashSha)
        #expect(repository.stash.current?.stashSha != first.stashSha)
        await app.idle()
    }

    @Test("follows the preference when no strategy is passed")
    func preference() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        app.preferences.uncommittedChangesStrategy = .stashOnCurrentBranch
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature) == .checkedOut(feature))
        #expect(try await stashList(local) == ["On main: !!Espalier<main>"])
        await app.idle()
    }

    @Test("brings changes that git can carry over along without a stash")
    func bringChangesDirectly() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature, strategy: .moveToNewBranch) == .checkedOut(feature))
        #expect(repository.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
        #expect(try await stashList(local).isEmpty)
        await app.idle()
    }

    @Test("brings changes git would overwrite along through a stash")
    func bringChangesThroughStash() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("README.md", mainReadme + "line 9\n", in: local)
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature, strategy: .moveToNewBranch) == .checkedOut(feature))
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(try read("README.md", in: local) == featureReadme + "line 9\n")
        #expect(try read("notes.txt", in: local) == "notes\n")
        #expect(try await stashList(local).isEmpty)
        #expect(repository.stash.conflictedRestore == nil)
        await app.idle()
    }

    @Test("a conflicting stash pop keeps the entry")
    func bringChangesConflict() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("README.md", mainReadme.replacingOccurrences(of: "line 1\n", with: "line uno\n"), in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature, strategy: .moveToNewBranch) == .checkedOut(feature))
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(try read("README.md", in: local).contains("<<<<<<<"))
        // The entry, labelled for the target branch, is kept until the
        // conflicts are resolved.
        #expect(try await stashList(local) == ["On main: !!Espalier<feature>"])
        #expect(repository.stash.conflictedRestore?.entry.branchName == "feature")
        #expect(repository.stash.conflictedRestore?.paths == ["README.md"])
        await app.idle()
    }

    @Test("on a detached HEAD changes always move to the new branch")
    func detachedHead() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try await runGit(["checkout", "--detach", "HEAD"], local)
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.full, reason: .user)
        guard case .detached = repository.gitState.tip else {
            Issue.record("Expected a detached HEAD, got \(repository.gitState.tip)")
            return
        }
        let feature = try branch("feature", in: repository)
        #expect(try await repository.branches.checkout(feature) == .checkedOut(feature))
        #expect(repository.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
        await app.idle()
    }

    @Test("local changes git would overwrite offer to stash and retry, which checks out")
    func localChangesOverwritten() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        // A change the model hasn't seen yet, so checking out runs.
        try harness.write("README.md", mainReadme + "local\n", in: local)
        let feature = try branch("feature", in: repository)

        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature)
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["README.md"]))
        #expect(error?.retry?.kind == .checkoutBranch)
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)
        #expect(recovery.isHeadless)
        await repository.idle()

        try await recovery.perform(in: app)
        await repository.idle()
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(try await stashList(local) == ["On main: !!Espalier<main>"])
        #expect(try read("README.md", in: local) == featureReadme)
        await app.idle()
    }

    @Test("an untracked file git would overwrite offers to stash and retry, which stashes the file and checks out")
    func untrackedFileOverwritten() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        // feature.txt is feature's; here it's untracked, unseen by the model.
        try harness.write("feature.txt", "my own feature notes\n", in: local)
        let feature = try branch("feature", in: repository)

        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature)
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["feature.txt"]))
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)
        await repository.idle()
        #expect(try read("feature.txt", in: local) == "my own feature notes\n")

        try await recovery.perform(in: app)
        await repository.idle()
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(try read("feature.txt", in: local) == "feature\n")
        #expect(repository.changes.workingDirectory.files.isEmpty)
        #expect(try await stashList(local) == ["On main: !!Espalier<main>"])
        // The stash holds the untracked file, and gives it back on main.
        #expect(try await runGit(["show", "stash@{0}:feature.txt"], local) == "my own feature notes\n")
        #expect(try await repository.branches.checkout(try branch("main", in: repository)) == .checkedOut(try branch("main", in: repository)))
        let entry = try #require(repository.stash.current)
        try await repository.stash.restore(entry)
        await repository.idle()
        #expect(try read("feature.txt", in: local) == "my own feature notes\n")
        #expect(try await stashList(local).isEmpty)
        await app.idle()
    }

    @Test("bringing along an untracked file the branch also has conflicts, and keeps the stash until it's resolved")
    func bringUntrackedFileOverwritten() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        try harness.write("feature.txt", "my own feature notes\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)

        #expect(try await repository.branches.checkout(feature, strategy: .moveToNewBranch) == .checkedOut(feature))
        #expect(repository.gitState.tip.branch?.name == "feature")
        let merged = try read("feature.txt", in: local)
        #expect(merged.contains("<<<<<<<") && merged.contains("my own feature notes") && merged.contains("feature\n"))
        #expect(try await stashList(local) == ["On main: !!Espalier<feature>"])
        #expect(repository.stash.conflictedRestore?.paths == ["feature.txt"])
        await app.idle()
    }

    @Test("checking out a remote branch makes a local branch that tracks it")
    func remoteBranch() async throws {
        let (local, remote) = try await setupRepositoryWithRemote()
        let other = try await cloneRepository(remote)
        try await runGit(["checkout", "-b", "topic"], other)
        try Data("topic\n".utf8).write(to: URL(filePath: other.path + "/topic.txt"))
        try await runGit(["add", "topic.txt"], other)
        try await runGit(["commit", "-m", "Topic"], other)
        try await runGit(["push", "origin", "topic"], other)
        try await runGit(["fetch", "origin"], local)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        let remoteTopic = try branch("origin/topic", in: repository)
        #expect(remoteTopic.type == .remote)

        #expect(try await repository.branches.checkout(remoteTopic) == .checkedOut(remoteTopic))
        let checkedOut = try #require(repository.gitState.tip.branch)
        #expect(checkedOut.name == "topic")
        #expect(checkedOut.upstream == "origin/topic")
        #expect(!repository.gitState.branches.all.contains { $0.name == "origin/topic" })
        await app.idle()
    }

    @Test("a branch checked out in another worktree switches to that worktree")
    func otherWorktree() async throws {
        let (_, app, repository, local) = try await makeRepository()
        let worktreePath = try createTempDirectory() + "/feature"
        try await runGit(["worktree", "add", worktreePath, "feature"], local)
        await repository.refresh(.full, reason: .user)
        #expect(repository.gitState.worktrees.count == 2)

        // The repository switches to the worktree (`switchToWorktree`) instead
        // of checking the branch out here.
        let worktree = try #require(repository.gitState.worktrees.first { $0.branch == "refs/heads/feature" })
        let result = try await repository.branches.checkout(try branch("feature", in: repository))
        #expect(result == .switchedToWorktree(worktree))
        #expect(repository.record.path == worktree.path)
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(app.selection == .repository(repository.id))
        await app.idle()
        #expect(repository.gitState.tip.branch?.name == "feature")
        #expect(try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], local) == "main\n")
    }

    /// Adds a worktree for `feature` with git, refreshes, then deletes its
    /// folder, as Finder would; returns the worktree's folder.
    private func addMissingWorktree(to repository: RepositoryModel, _ local: Repository) async throws -> String {
        let worktreePath = try createTempDirectory() + "/feature"
        try await runGit(["worktree", "add", worktreePath, "feature"], local)
        await repository.refresh(.full, reason: .user)
        try FileManager.default.removeItem(atPath: worktreePath)
        return worktreePath
    }

    @Test("a branch checked out in a worktree whose folder is gone asks, then removes that worktree and checks the branch out here")
    func missingWorktree() async throws {
        let (_, app, repository, local) = try await makeRepository()
        _ = try await addMissingWorktree(to: repository, local)
        let feature = try branch("feature", in: repository)

        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .removeMissingWorktree)
        #expect(try await listWorktrees(local).count == 2)

        #expect(try await repository.branches.checkout(feature, confirmed: [.removeMissingWorktree]) == .checkedOut(feature))
        #expect(try await listWorktrees(local).count == 1)
        #expect(try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], local) == "feature\n")
        #expect(repository.record.path == local.path)
        #expect(repository.gitState.tip.branch?.name == "feature")
        await app.idle()
        #expect(repository.gitState.worktrees.count == 1)
    }

    @Test("the missing worktree's question comes before the changes', and nothing is removed until both are answered")
    func missingWorktreeWithChanges() async throws {
        let (harness, app, repository, local) = try await makeRepository()
        _ = try await addMissingWorktree(to: repository, local)
        try harness.write("notes.txt", "notes\n", in: local)
        await repository.refresh(.status, reason: .user)
        let feature = try branch("feature", in: repository)

        let first = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature)
        }
        guard case .confirmationRequired(let confirmation)? = first?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: first))")
            return
        }
        #expect(confirmation.kind == .removeMissingWorktree)
        let second = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature, confirmed: [.removeMissingWorktree])
        }
        #expect(second?.reason == .decisionRequired(.uncommittedChanges(currentBranch: "main", targetBranch: "feature")))
        #expect(try await listWorktrees(local).count == 2)

        let result = try await repository.branches.checkout(feature, strategy: .stashOnCurrentBranch, confirmed: [.removeMissingWorktree])
        #expect(result == .checkedOut(feature))
        #expect(try await listWorktrees(local).count == 1)
        #expect(try await stashList(local) == ["On main: !!Espalier<main>"])
        #expect(repository.gitState.tip.branch?.name == "feature")
        await app.idle()
    }

    @Test("a missing worktree whose folder is back by the answer is switched to, not removed")
    func missingWorktreeThatCameBack() async throws {
        let (_, app, repository, local) = try await makeRepository()
        let worktreePath = try createTempDirectory() + "/feature"
        try await runGit(["worktree", "add", worktreePath, "feature"], local)
        await repository.refresh(.full, reason: .user)
        let worktree = try #require(repository.gitState.worktrees.first { $0.branch == "refs/heads/feature" })
        let away = POSIXPath.join(try createTempDirectory(), "away")
        try FileManager.default.moveItem(atPath: worktreePath, toPath: away)
        let feature = try branch("feature", in: repository)

        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(feature)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .removeMissingWorktree)

        // The folder comes back between the question and the answer.
        try FileManager.default.moveItem(atPath: away, toPath: worktreePath)
        let result = try await repository.branches.checkout(feature, confirmed: [.removeMissingWorktree])
        #expect(result == .switchedToWorktree(worktree))
        #expect(repository.record.path == worktree.path)
        #expect(try await listWorktrees(local).count == 2)
        #expect(try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], local) == "main\n")
        await app.idle()
    }

    @Test("during the checkout, the worktree holding the branch is removed only while its folder is gone")
    func removeMissingWorktreeInCheckout() async throws {
        let (_, app, repository, local) = try await makeRepository()
        let worktreePath = try createTempDirectory() + "/feature"
        try await runGit(["worktree", "add", worktreePath, "feature"], local)
        let holding = { () async throws -> WorktreeEntry? in
            try await repository.perform(OperationDescriptor(kind: .checkoutBranch)) { ctx in
                try await repository.worktrees.removeMissingWorktree(holding: "refs/heads/feature", in: ctx)
            }
        }

        let listed = try #require(try await listWorktrees(local).first { $0.branch == "refs/heads/feature" })
        #expect(try await holding() == listed)
        #expect(try await listWorktrees(local).count == 2)

        try FileManager.default.removeItem(atPath: worktreePath)
        #expect(try await holding() == nil)
        #expect(try await listWorktrees(local).count == 1)

        // Nothing holds the branch now.
        #expect(try await holding() == nil)
        await app.idle()
    }

    @Test("checking out while another local operation runs is busy")
    func busy() async throws {
        let (_, app, repository, _) = try await makeRepository()
        let gate = AsyncGate()
        let other = Task {
            try await repository.perform(OperationDescriptor(kind: .commit)) { _ in
                await gate.wait()
            }
        }
        try await gate.waitUntilWaiting()
        let error = await #expect(throws: OperationError.self) {
            try await repository.branches.checkout(try branch("feature", in: repository))
        }
        #expect(error?.reason == .busy(.commit))
        gate.open()
        try await other.value
        await app.idle()
    }
}

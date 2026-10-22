// What the window's actions allow, and what they say when they can't run:
// Check Out during a merge says why and leaves the branch alone; the Commit
// menu's items act only where commits show; Revert takes only the checked-out
// branch's commits; the history scope is the graph's; Stash All on a detached
// HEAD says why; ⌘↩ presses Commit Merge and Continue; and the Keyboard
// Shortcuts sheet leaves out what the menus hide.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Action availability", .offline, .hangGuard(minutes: 5)) @MainActor
struct ActionAvailabilityTests {
    @Test("Check Out during a merge is refused with the reason, in a toast, and the branch stays")
    func checkOutDuringMerge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let actions = fixture.context.actions
            #expect(actions.disabledReason(.checkoutBranch(name: "other")) == nil)

            #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
            await fixture.refresh()
            let reason = try #require(actions.disabledReason(.checkoutBranch(name: "other")))
            #expect(reason == fixture.repository.operations.checkoutRefusal)

            actions.perform(.checkoutBranch(name: "other"))
            await fixture.settle()
            #expect(fixture.presenter.toasts.last?.message == reason)
            #expect(try await fixture.currentBranch() == "feature")
        }
    }

    @Test("Cherry-pick, Squash, and Copy SHA from the menu bar act only where commits show; named commits work anywhere")
    func commitMenuOutsideHistory() async throws {
        let fixture = try await makeConflictingFixture()
        await fixture.loadHistory()
        let actions = fixture.context.actions
        let history = fixture.repository.history
        let head = try await fixture.sha("HEAD")
        let parent = try await fixture.sha("HEAD~1")

        fixture.context.select(.changes)
        history.select(shas: [head, parent], contiguous: true)
        for action in [ActionID.cherryPick(shas: nil, target: nil), .squash(shas: nil, into: nil), .copySHA(shas: nil)] {
            #expect(!actions.canPerform(action))
            #expect(actions.disabledReason(action) != nil)
        }
        #expect(actions.canPerform(.copySHA(shas: [head])))
        #expect(actions.canPerform(.cherryPick(shas: [head], target: nil)))

        fixture.context.select(.history)
        history.select(shas: [head, parent], contiguous: true)
        #expect(actions.canPerform(.cherryPick(shas: nil, target: nil)))
        #expect(actions.canPerform(.copySHA(shas: nil)))
        #expect(actions.canPerform(.squash(shas: nil, into: nil)))
    }

    @Test("in the graph, Revert takes the checked-out branch's commits and says why for another branch's")
    func revertInGraph() async throws {
        let fixture = try await makeConflictingFixture()
        fixture.repository.history.setStyle(.graph)
        await fixture.loadHistory()
        let actions = fixture.context.actions
        let feature = try await fixture.sha("feature")
        // Only on main: in the graph of local branches, beside feature's.
        let mainOnly = try await fixture.sha("main")
        fixture.context.select(.history)
        #expect(fixture.repository.history.commit(mainOnly) != nil)

        #expect(actions.canPerform(.revertCommit(sha: feature)))
        #expect(actions.disabledReason(.revertCommit(sha: feature)) == nil)
        #expect(!actions.canPerform(.revertCommit(sha: mainOnly)))
        #expect(actions.disabledReason(.revertCommit(sha: mainOnly)) != nil)
    }

    @Test("in another branch's history, Revert is refused with a reason, even for a commit the branches share")
    func revertInAnotherBranchsHistory() async throws {
        let fixture = try await makeConflictingFixture()
        fixture.repository.history.setStyle(.simple)
        await fixture.loadHistory()
        let actions = fixture.context.actions
        let history = fixture.repository.history
        let mainOnly = try await fixture.sha("main")
        let shared = try await fixture.sha("other")

        history.showBranch(ref: "refs/heads/main")
        await fixture.settle()
        for sha in [mainOnly, shared] {
            #expect(history.commit(sha) != nil)
            #expect(!actions.canPerform(.revertCommit(sha: sha)))
            #expect(actions.disabledReason(.revertCommit(sha: sha)) != nil)
        }

        history.showBranch(ref: nil)
        await fixture.settle()
        #expect(actions.canPerform(.revertCommit(sha: shared)))
    }

    @Test("the history scope is the graph's: disabled, with a reason, in the simple list")
    func scopeInSimpleList() async throws {
        let fixture = try await makeConflictingFixture()
        let actions = fixture.context.actions
        let history = fixture.repository.history

        history.setStyle(.simple)
        await fixture.loadHistory()
        #expect(!actions.canPerform(.setHistoryScope(.allBranches)))
        #expect(actions.disabledReason(.setHistoryScope(.allBranches)) != nil)

        history.setStyle(.graph)
        await fixture.settle()
        #expect(actions.canPerform(.setHistoryScope(.allBranches)))
    }

    @Test("Stash All Changes on a detached HEAD says why it can't run")
    func stashOnDetachedHead() async throws {
        let fixture = try await makeConflictingFixture()
        let actions = fixture.context.actions
        try fixture.harness.write("feature.txt", "changed\n", in: fixture.local)
        await fixture.refresh()
        #expect(actions.canPerform(.stashAllChanges))
        #expect(actions.disabledReason(.stashAllChanges) == nil)

        try await fixture.git(["checkout", "-q", "--detach"])
        await fixture.refresh()
        #expect(!actions.canPerform(.stashAllChanges))
        #expect(actions.disabledReason(.stashAllChanges) != nil)
    }

    @Test("⌘↩ presses Commit Merge once the merge's conflicts are resolved, and commits the merge")
    func commitMergeShortcut() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let actions = fixture.context.actions
            fixture.context.select(.changes)

            #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
            await fixture.refresh()
            #expect(!actions.canPerform(.commitChanges))

            try fixture.harness.write("README.md", "resolved\n", in: fixture.local)
            try await fixture.git(["add", "README.md"])
            await fixture.refresh()
            #expect(actions.canPerform(.commitChanges))

            await actions.performAndWait(.commitChanges)
            await fixture.settle()
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", "MERGE_HEAD")))
            let parents = try await fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"])
            #expect(parents.split(separator: " ").count == 3)
            #expect(try await fixture.currentBranch() == "feature")
        }
    }

    @Test("⌘↩ presses Continue once a rebase's conflicts are resolved, and the rebase finishes")
    func continueRebaseShortcut() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            let actions = fixture.context.actions
            fixture.context.select(.changes)

            #expect(try await fixture.repository.operations.rebase(onto: try fixture.branch("main")) == .conflicted)
            await fixture.refresh()
            #expect(!actions.canPerform(.commitChanges))

            try fixture.harness.write("README.md", "resolved\n", in: fixture.local)
            try await fixture.git(["add", "README.md"])
            await fixture.refresh()
            #expect(actions.canPerform(.commitChanges))

            await actions.performAndWait(.commitChanges)
            await fixture.settle()
            for directory in ["rebase-merge", "rebase-apply"] {
                #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", directory)))
            }
            #expect(try await fixture.currentBranch() == "feature")
            #expect(try await fixture.summaries("main..feature") == ["Feature", "Feature README"])
        }
    }

    @Test("the Keyboard Shortcuts sheet leaves out what the menus hide: Generate Commit Message with AI off")
    func shortcutsLeaveOutHiddenItems() async throws {
        let fixture = try await makeOperationsFixture()
        let actions = fixture.context.actions
        func listsGenerate() -> Bool {
            ShortcutListing.listings { actions.isHidden($0) }.contains { $0.kind == .generateCommitMessage }
        }

        fixture.app.preferences.aiFeaturesEnabled = true
        #expect(listsGenerate())
        fixture.app.preferences.aiFeaturesEnabled = false
        #expect(!listsGenerate())
    }
}

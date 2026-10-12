// The branch actions on real repositories, through the window's presenter:
// checkout with the Switch Branch decision, New Branch's create then
// checkout (created once across the decision), rename, delete with and
// without the remote, the menu bar's rules, merge, squash merge, rebase with
// its force push confirmation, Update from <default>, and Restore Pruned
// Branch.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch actions", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchActionsTests {
    @Test("checking out with changes asks the Switch Branch decision and brings them along")
    func checkoutWithDecision() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["branch", "feature"], local)
            }
            fixture.app.preferences.uncommittedChangesStrategy = .askForConfirmation
            try fixture.harness.write("README.md", "changed\n", in: fixture.local)
            await fixture.refresh()

            #expect(fixture.context.actions.canPerform(.checkoutBranch(name: "feature")))
            #expect(!fixture.context.actions.canPerform(.checkoutBranch(name: "main")))
            #expect(!fixture.context.actions.canPerform(.checkoutBranch(name: "missing")))
            fixture.context.actions.perform(.checkoutBranch(name: "feature"))
            let decision = await fixture.decision()
            #expect(decision.decision == .uncommittedChanges(currentBranch: "main", targetBranch: "feature", currentBranchHasStash: false))
            fixture.presenter.respond(to: decision.id, with: .moveToNewBranch)
            await fixture.settle()

            #expect(try await fixture.currentBranch() == "feature")
            #expect(try String(contentsOfFile: POSIXPath.join(fixture.local.path, "README.md"), encoding: .utf8) == "changed\n")
            #expect(fixture.presenter.error == nil)
            #expect(fixture.presenter.toasts.isEmpty)
        }
    }

    @Test("leaving changes on a branch with a stash asks once: the Switch Branch decision's warning; the preference alone asks Overwrite Stash")
    func overwriteStashAskedOnce() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["branch", "feature"], local)
            }
            // main has a stash, and new changes.
            try fixture.harness.write("README.md", "first\n", in: fixture.local)
            await fixture.refresh()
            #expect(try await fixture.repository.stash.stashAllChanges())
            try fixture.harness.write("README.md", "second\n", in: fixture.local)
            await fixture.refresh()

            // The decision warns, and choosing to leave the changes is the
            // confirmation.
            fixture.app.preferences.uncommittedChangesStrategy = .askForConfirmation
            fixture.context.actions.perform(.checkoutBranch(name: "feature"))
            let decision = await fixture.decision()
            #expect(decision.decision == .uncommittedChanges(currentBranch: "main", targetBranch: "feature", currentBranchHasStash: true))
            fixture.presenter.respond(to: decision.id, with: .stashOnCurrentBranch)
            await waitUntil { fixture.presenter.confirmation != nil || fixture.repository.gitState.tip.branch?.name == "feature" }
            #expect(fixture.presenter.confirmation == nil)
            await fixture.settle()
            #expect(try await fixture.currentBranch() == "feature")
            #expect(try await fixture.git(["stash", "list", "--format=%gs"]) == "On main: !!Espalier<main>\n")
            #expect(try await fixture.git(["stash", "show", "-p", "stash@{0}"]).contains("+second"))
            #expect(fixture.presenter.error == nil)

            // With the preference set to leave changes, no decision warns:
            // Overwrite Stash? asks.
            try await fixture.git(["checkout", "-q", "main"])
            try fixture.harness.write("README.md", "third\n", in: fixture.local)
            await fixture.refresh()
            fixture.app.preferences.uncommittedChangesStrategy = .stashOnCurrentBranch
            fixture.context.actions.perform(.checkoutBranch(name: "feature"))
            let overwrite = await fixture.confirmation()
            #expect(overwrite.confirmation.kind == .overwriteStash)
            fixture.presenter.respond(to: overwrite.id, with: ConfirmationResponse(isConfirmed: true))
            await fixture.settle()
            #expect(fixture.presenter.confirmation == nil)
            #expect(try await fixture.currentBranch() == "feature")
            #expect(try await fixture.git(["stash", "show", "-p", "stash@{0}"]).contains("+third"))
        }
    }

    @Test("New Branch creates the branch once, then checks it out with the decision's answer")
    func createWithDecision() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture()
            fixture.app.preferences.uncommittedChangesStrategy = .askForConfirmation
            try fixture.harness.write("README.md", "changed\n", in: fixture.local)
            await fixture.refresh()

            let create = Task {
                await BranchActions.create("topic", startPoint: .currentBranch, mode: .create, in: fixture.context)
            }
            let decision = await fixture.decision()
            fixture.presenter.respond(to: decision.id, with: .stashOnCurrentBranch)
            await create.value
            await fixture.settle()

            #expect(fixture.presenter.error == nil)
            #expect(try await fixture.currentBranch() == "topic")
            // The changes stayed on main, in its stash.
            #expect(try await fixture.git(["stash", "list", "--format=%gs"]).contains("main"))
            #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
        }
    }

    @Test("Create Branch from Commit starts at the commit and checks it out")
    func createFromCommit() async throws {
        try await withIsolatedGitConfig { _ in
            var first = ""
            let fixture = try await makeOperationsFixture { local in
                first = try await runGit(["rev-parse", "HEAD"], local).trimmingCharacters(in: .whitespacesAndNewlines)
                try await commitFile(local, "two.txt", "two\n")
            }
            #expect(fixture.context.actions.canPerform(.newBranch(startPoint: first)))
            await BranchActions.create("from-commit", startPoint: .head, mode: .startPoint(first, summary: "Initial commit"), in: fixture.context)
            await fixture.settle()
            #expect(try await fixture.currentBranch() == "from-commit")
            #expect(try await fixture.sha("HEAD") == first)
        }
    }

    @Test("Rename renames; Delete with the remote deletes both; the pull request variant deletes only the local branch")
    func renameAndDelete() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                for name in ["published", "kept-on-remote"] {
                    try await runGit(["checkout", "-q", "-b", name], local)
                    try await commitFile(local, "\(name).txt", "\(name)\n")
                    try await runGit(["push", "-q", "-u", "origin", name], local)
                }
                try await runGit(["checkout", "-q", "-b", "local-only", "main"], local)
                try await runGit(["checkout", "-q", "main"], local)
            }

            // Rename.
            await BranchActions.rename(try fixture.branch("local-only"), to: "renamed", in: fixture.context)
            await fixture.settle()
            #expect(try await fixture.git(["branch", "--list", "renamed"]).contains("renamed"))
            #expect(try await fixture.git(["branch", "--list", "local-only"]).isEmpty)

            // Delete, with the remote.
            fixture.context.actions.perform(.deleteBranch(name: "published"))
            let confirmation = await fixture.confirmation()
            #expect(confirmation.confirmation.kind == .deleteBranch)
            #expect(confirmation.confirmation.details == .deleteBranch(name: "published", existsOnRemote: true))
            fixture.presenter.respond(to: confirmation.id, with: ConfirmationResponse(isConfirmed: true, isOptionSelected: true))
            await fixture.settle()
            #expect(try await fixture.git(["branch", "--list", "published"]).isEmpty)
            #expect(try await runGit(["branch", "--list", "published"], fixture.remote).isEmpty)

            // The pull request variant: only the local branch.
            await BranchActions.deleteLocalBranch(try fixture.branch("kept-on-remote"), in: fixture.context)
            await fixture.settle()
            #expect(try await fixture.git(["branch", "--list", "kept-on-remote"]).isEmpty)
            #expect(try await runGit(["branch", "--list", "kept-on-remote"], fixture.remote).contains("kept-on-remote"))
            #expect(fixture.presenter.error == nil)
        }
    }

    @Test("the menu bar's Rename and Delete follow the current branch; rows name any branch")
    func menuRules() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["branch", "feature"], local)
                // A branch only the remote has.
                try await runGit(["push", "-q", "origin", "main:remote-only"], local)
                try await runGit(["fetch", "-q", "origin"], local)
            }
            let actions = fixture.context.actions
            // On the published default branch.
            #expect(!actions.canPerform(.deleteBranch(name: nil)))
            #expect(!actions.canPerform(.renameBranch(name: nil)))
            #expect(actions.canPerform(.deleteBranch(name: "feature")))
            #expect(actions.canPerform(.renameBranch(name: "feature")))
            #expect(!actions.canPerform(.renameBranch(name: "origin/remote-only")))
            #expect(actions.canPerform(.deleteBranch(name: "origin/remote-only")))
            // Merging and rebasing need a branch other than the current one.
            #expect(actions.canPerform(.mergeIntoCurrentBranch(branch: "feature")))
            #expect(!actions.canPerform(.mergeIntoCurrentBranch(branch: "main")))
            #expect(actions.canPerform(.rebaseCurrentBranch(onto: nil)))

            try await fixture.git(["checkout", "-q", "feature"])
            await fixture.refresh()
            #expect(actions.canPerform(.deleteBranch(name: nil)))
            #expect(actions.canPerform(.renameBranch(name: nil)))

            try await fixture.git(["checkout", "-q", "--detach"])
            await fixture.refresh()
            #expect(!actions.canPerform(.mergeIntoCurrentBranch(branch: nil)))
            #expect(!actions.canPerform(.renameBranch(name: nil)))
        }
    }

    @Test("merge brings in the branch's commits; squash merge makes one commit of them")
    func merge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                for name in ["feature", "squashed"] {
                    try await runGit(["checkout", "-q", "-b", name, "main"], local)
                    try await commitFile(local, "\(name)-1.txt", "1\n")
                    try await commitFile(local, "\(name)-2.txt", "2\n")
                }
                try await runGit(["checkout", "-q", "main"], local)
            }
            await BranchActions.integrate(.merge, branch: try fixture.branch("feature"), in: fixture.context)
            await fixture.settle()
            #expect(try await fixture.summaries("main").contains("Change feature-2.txt"))

            await BranchActions.integrate(.squashMerge, branch: try fixture.branch("squashed"), in: fixture.context)
            await fixture.settle()
            // One commit with both changes.
            #expect(try await fixture.git(["rev-list", "--count", "HEAD^..HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            #expect(try await fixture.git(["show", "--name-only", "--format=", "HEAD"]).contains("squashed-2.txt"))
        }
    }

    @Test("rebasing published commits asks first; Update from main merges main")
    func rebaseAndUpdate() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "feature.txt", "feature\n")
                try await runGit(["push", "-q", "-u", "origin", "feature"], local)
                try await runGit(["checkout", "-q", "-b", "updated", "main"], local)
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "main.txt", "main\n")
                try await runGit(["checkout", "-q", "feature"], local)
            }
            fixture.app.preferences.confirmForcePush = true
            let rebase = Task {
                await BranchActions.integrate(.rebase, branch: try fixture.branch("main"), in: fixture.context)
            }
            let confirmation = await fixture.confirmation()
            #expect(confirmation.confirmation.kind == .rewritePublishedCommits)
            fixture.presenter.respond(to: confirmation.id, with: ConfirmationResponse(isConfirmed: true))
            _ = await rebase.result
            await fixture.settle()
            #expect(try await fixture.summaries("feature").prefix(2) == ["Change feature.txt", "Change main.txt"])

            // Update from main, on another branch: a merge of main.
            try await fixture.git(["checkout", "-q", "updated"])
            await fixture.refresh()
            #expect(fixture.context.actions.canPerform(.updateFromDefaultBranch))
            await fixture.context.actions.performAndWait(.updateFromDefaultBranch)
            await fixture.settle()
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "main.txt")))
        }
    }

    @Test("Restore Pruned Branch recreates the branch at its commit")
    func restorePruned() async throws {
        try await withIsolatedGitConfig { _ in
            var sha = ""
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "old"], local)
                sha = try await commitFile(local, "old.txt", "old\n")
                try await runGit(["checkout", "-q", "main"], local)
                try await runGit(["branch", "-q", "-D", "old"], local)
            }
            fixture.repository.sync.prunedBranches = [PrunedBranch(name: "old", sha: sha, date: UIFixtures.now)]
            #expect(fixture.context.actions.canPerform(.restorePrunedBranch(name: "old")))
            #expect(!fixture.context.actions.canPerform(.restorePrunedBranch(name: "other")))
            await fixture.context.actions.performAndWait(.restorePrunedBranch(name: "old"))
            await fixture.settle()
            #expect(try await fixture.sha("old") == sha)
            #expect(fixture.repository.sync.prunedBranches.isEmpty)
        }
    }
}

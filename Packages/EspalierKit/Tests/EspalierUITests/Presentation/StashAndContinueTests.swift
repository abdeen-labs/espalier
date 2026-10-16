// The presenter runs "Stash Changes and Continue" in two steps, each asking
// its own questions, so the changes are stashed once and the squash,
// reorder, or rebase runs with the force push warning's answer; the
// operation run again reports its outcome as a first run does (its toast,
// with Undo).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Observation
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Stash Changes and Continue", .offline, .hangGuard(minutes: 5)) @MainActor
struct StashAndContinueTests {
    /// `main` with README, A, B, and C, published; a change to A.txt.
    private func publishedFixture() async throws -> OperationsFixture {
        let fixture = try await makeOperationsFixture { local in
            for name in ["A", "B", "C"] {
                try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
            }
            try await runGit(["push", "-q", "-u", "origin", "main"], local)
        }
        fixture.app.preferences.confirmForcePush = true
        await fixture.loadHistory()
        try fixture.harness.write("A.txt", "changed\n", in: fixture.local)
        await fixture.refresh()
        return fixture
    }

    /// Runs `start`, which ends on local changes in the way; recovers with
    /// Stash Changes and Continue; confirms the force push warning; and
    /// checks that nothing else was asked and nothing failed.
    private func stashAndContinue(_ fixture: OperationsFixture, _ start: @escaping @MainActor () async -> Void) async throws {
        await start()
        let presented = try #require(fixture.presenter.error)
        guard case .localChangesOverwritten = presented.error.reason else {
            Issue.record("Unexpected error \(presented.error.reason)")
            return
        }
        let recovery = try #require(presented.error.recoveries.first)
        guard case .stashChangesAndRetry = recovery else {
            Issue.record("Unexpected recovery \(recovery.title)")
            return
        }

        let done = Flag()
        let recover = Task {
            await fixture.presenter.recover(presented.id, with: recovery)
            done.isSet = true
        }
        let warning = await fixture.confirmation()
        #expect(warning.confirmation.kind == .rewritePublishedCommits)
        fixture.presenter.respond(to: warning.id, with: ConfirmationResponse(isConfirmed: true))

        // Nothing else is asked.
        await waitUntil { done.isSet || fixture.presenter.confirmation != nil }
        if let asked = fixture.presenter.confirmation {
            Issue.record("Asked again: \(asked.confirmation.kind)")
            fixture.presenter.respond(to: asked.id, with: .cancelled)
        }
        await recover.value
        await fixture.settle()
        #expect(fixture.presenter.error == nil)
        // One stash, the branch's, with the change.
        #expect(try await fixture.git(["stash", "list", "--format=%gs"]) == "On main: !!Espalier<main>\n")
        #expect(try await fixture.git(["stash", "show", "--name-only", "stash@{0}"]) == "A.txt\n")
        #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("a squash of published commits stashes once, then asks about the force push and squashes")
    func squash() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await publishedFixture()
            let b = try await fixture.sha("main~1"), c = try await fixture.sha("main")
            let plan = try #require(SquashPlan.make(shas: [b, c], into: nil, in: fixture.repository))
            try await stashAndContinue(fixture) {
                await MultiCommitActions.squash(plan, message: CommitContext(summary: "B and C", description: nil), in: fixture.context)
            }
            #expect(try await fixture.summaries("main").prefix(2) == ["B and C", "A"])

            // The squash's toast, with its Undo, which undoes it.
            let toast = try #require(fixture.presenter.toasts.last)
            let undo = try #require(fixture.presenter.takeToastUndo(toast.id))
            await undo.perform()
            await fixture.settle()
            #expect(fixture.presenter.error == nil)
            #expect(try await fixture.summaries("main").prefix(3) == ["C", "B", "A"])
        }
    }

    @Test("a reorder of published commits stashes once, then asks about the force push and reorders")
    func reorder() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await publishedFixture()
            let a = try await fixture.sha("main~2"), c = try await fixture.sha("main")
            let history = fixture.repository.history
            let rewrite = try #require(history.currentBranchRewrite(moving: [c], relativeTo: a))
            try await stashAndContinue(fixture) {
                await KeyboardReorder.perform(rewrite, below: history.commit(a), repository: fixture.repository, context: fixture.context)
            }
            #expect(try await fixture.summaries("main").prefix(3) == ["B", "A", "C"])
            // The reorder's toast, with Undo.
            let toast = try #require(fixture.presenter.toasts.last)
            #expect(toast.undo != nil)
        }
    }

    @Test("a rebase of a published branch stashes once, then asks about the force push and rebases")
    func rebase() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["checkout", "-q", "-b", "upstream"], local)
                try await commitFile(local, "upstream.txt", "upstream\n", message: "Upstream")
                try await runGit(["checkout", "-q", "main"], local)
                try await commitFile(local, "A.txt", "A\n", message: "A")
                try await runGit(["push", "-q", "-u", "origin", "main"], local)
            }
            fixture.app.preferences.confirmForcePush = true
            try fixture.harness.write("A.txt", "changed\n", in: fixture.local)
            await fixture.refresh()
            let upstream = try fixture.branch("upstream")
            try await stashAndContinue(fixture) {
                await BranchActions.integrate(.rebase, branch: upstream, in: fixture.context)
            }
            #expect(try await fixture.summaries("main").prefix(2) == ["A", "Upstream"])
            let toast = try #require(fixture.presenter.toasts.last)
            #expect(toast.undo == nil)
        }
    }

    @Test("a merge stashes the changes in its way, merges, and shows its toast")
    func merge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await commitFile(local, "A.txt", "A\n", message: "A")
                try await runGit(["checkout", "-q", "-b", "feature"], local)
                try await commitFile(local, "A.txt", "feature\n", message: "Feature A")
                try await runGit(["checkout", "-q", "main"], local)
            }
            try fixture.harness.write("A.txt", "changed\n", in: fixture.local)
            await fixture.refresh()
            let feature = try fixture.branch("feature")

            await BranchActions.integrate(.merge, branch: feature, in: fixture.context)
            let presented = try #require(fixture.presenter.error)
            let recovery = try #require(presented.error.recoveries.first)
            guard case .stashChangesAndRetry = recovery else {
                Issue.record("Unexpected recovery \(recovery.title)")
                return
            }
            #expect(fixture.presenter.toasts.isEmpty)

            await fixture.presenter.recover(presented.id, with: recovery)
            await fixture.settle()
            #expect(fixture.presenter.error == nil)
            #expect(try await fixture.summaries("main").first == "Feature A")
            #expect(fixture.presenter.toasts.count == 1)
        }
    }

    @Test("with a stash on the branch already, it's offered, stashes the changes as another entry without asking, and the operation runs")
    func branchHasStash() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await publishedFixture()
            fixture.app.preferences.confirmForcePush = false
            // The change to A.txt is the branch's stash; then another change.
            #expect(try await fixture.repository.stash.stashAllChanges())
            try fixture.harness.write("B.txt", "changed\n", in: fixture.local)
            await fixture.refresh()

            let b = try await fixture.sha("main~1"), c = try await fixture.sha("main")
            let plan = try #require(SquashPlan.make(shas: [b, c], into: nil, in: fixture.repository))
            await MultiCommitActions.squash(plan, message: CommitContext(summary: "B and C", description: nil), in: fixture.context)
            let presented = try #require(fixture.presenter.error)
            let recovery = try #require(presented.error.recoveries.first)
            guard case .stashChangesAndRetry = recovery else {
                Issue.record("Unexpected recovery \(recovery.title)")
                return
            }

            let done = Flag()
            let recover = Task {
                await fixture.presenter.recover(presented.id, with: recovery)
                done.isSet = true
            }
            await waitUntil { done.isSet || fixture.presenter.confirmation != nil }
            if let asked = fixture.presenter.confirmation {
                Issue.record("Asked: \(asked.confirmation.kind)")
                fixture.presenter.respond(to: asked.id, with: .cancelled)
            }
            await recover.value
            await fixture.settle()
            #expect(fixture.presenter.error == nil)
            #expect(try await fixture.summaries("main").prefix(2) == ["B and C", "A"])
            // Both entries are the branch's, the new one on top.
            #expect(try await fixture.git(["stash", "list", "--format=%gs"]) == "On main: !!Espalier<main>\nOn main: !!Espalier<main>\n")
            #expect(try await fixture.git(["stash", "show", "--name-only", "stash@{0}"]) == "B.txt\n")
            #expect(try await fixture.git(["stash", "show", "--name-only", "stash@{1}"]) == "A.txt\n")
        }
    }
}

/// A flag a task sets for the test to wait on (observable, for `waitUntil`).
@MainActor @Observable
private final class Flag {
    var isSet = false
}

// These drive `SyncModel.push` against local bare remotes: publishing a
// branch, tags, force with lease and its confirmation, the lease refusing
// unfetched commits, a retry that keeps its options, a rejected push and
// its Fetch recovery, the fetch after the push failing, preconditions, and
// the pre-push hook.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Push", .offline) @MainActor
struct PushOperationTests {
    /// A selected repository whose `main` was pushed with a commit on top of
    /// the seed, then amended locally (diverged from `origin/main`), with the
    /// rewrite recorded as an amend would record it.
    private func makeRewrittenRepository(
        responder: PromptCenter.Responder? = PromptResponder.failing()
    ) async throws -> (fixture: SelectedRepository, amended: String) {
        let fixture = try await makeSelectedRepository(responder: responder) { local in
            try await commitFile(local, "a.txt", "a\n", message: "Add a")
            try await runGit(["push", "-q", "origin", "main"], local)
        }
        let pushed = try await fixture.head()
        try await runGit(["commit", "-q", "--amend", "-m", "Add a (amended)"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let branch = try #require(fixture.model.gitState.tip.branch)
        fixture.model.operations.recordRewrite(of: branch, previousTip: pushed)
        return (fixture, try await fixture.head())
    }

    @Test("publishes a branch without an upstream and tracks it")
    func publishBranch() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        #expect(fixture.model.sync.action == .publishBranch(remote: "origin", isGitHubRepository: false))

        let outcome = try await fixture.model.sync.publishBranch()

        #expect(outcome == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await fixture.remoteTip("feature") == (try await fixture.head()))
        #expect(try await fixture.localSHA("feature@{upstream}") == (try await fixture.head()))
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/feature")
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.publishBranch)))
        await fixture.app.idle()
    }

    @Test("pushes commits and returns after the refresh")
    func pushes() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        #expect(fixture.model.sync.action == .push(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 0), tagsToPush: 0))

        #expect(try await fixture.model.sync.push() == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))

        #expect(try await fixture.remoteTip("main") == (try await fixture.head()))
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        await fixture.app.idle()
    }

    @Test("pushes a branch tracking a branch of another name to that branch")
    func upstreamOfAnotherName() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "topic", "--track", "origin/main"], local)
            try await commitFile(local, "topic.txt", "topic\n")
        }
        #expect(try await fixture.model.sync.push() == .pushed(branch: "topic", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await fixture.remoteTip("main") == (try await fixture.head()))
        #expect(try await fixture.remoteTip("topic") == nil)
        await fixture.app.idle()
    }

    @Test("pushes the queued tags with the branch and takes them off the queue")
    func tags() async throws {
        let fixture = try await makeSelectedRepository()
        try await fixture.model.branches.createTag("v1.0", at: try await fixture.head())
        #expect(fixture.model.branches.tagsToPush == ["v1.0"])
        #expect(fixture.model.sync.action == .push(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 0), tagsToPush: 1))

        #expect(try await fixture.model.sync.push() == .pushed(branch: "main", remote: "origin", tags: ["v1.0"], fetchFailure: nil))

        #expect(try await resolveRef("refs/tags/v1.0", in: fixture.remote) != nil)
        #expect(fixture.model.branches.tagsToPush.isEmpty)
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        await fixture.app.idle()
    }

    @Test("a tag queued while a push ran stays queued")
    func tagQueuedDuringPush() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.app.updateRecord(fixture.model.id) { $0.tagsToPush = ["v1", "v2"] }
        fixture.model.sync.removePushedTags(["v1"])
        #expect(fixture.model.branches.tagsToPush == ["v2"])
        fixture.model.sync.removePushedTags(["v2"])
        #expect(fixture.model.branches.tagsToPush.isEmpty)
        await fixture.app.idle()
    }

    // MARK: Force push

    @Test("a force push asks first, then overwrites the rewritten history with lease and forgets the rewrite")
    func forcePush() async throws {
        let (fixture, amended) = try await makeRewrittenRepository()
        #expect(fixture.model.operations.forcePushState == .recommended)
        #expect(fixture.model.sync.action == .forcePush(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 1), tagsToPush: 0))

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(PushRequest(forceWithLease: true))
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .forcePush)
        #expect(confirmation.details == .branch("origin/main"))
        #expect(try await fixture.remoteTip("main") != amended)

        let outcome = try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])

        #expect(outcome == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await fixture.remoteTip("main") == amended)
        #expect(fixture.model.operations.rewrittenBranches["main"] == nil)
        #expect(fixture.model.operations.forcePushState == .notAvailable)
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        await fixture.app.idle()
    }

    @Test("with confirmForcePush off, a force push doesn't ask")
    func forcePushWithoutConfirmation() async throws {
        let (fixture, amended) = try await makeRewrittenRepository()
        fixture.app.preferences.confirmForcePush = false
        _ = try await fixture.model.sync.push(PushRequest(forceWithLease: true))
        #expect(try await fixture.remoteTip("main") == amended)
        await fixture.app.idle()
    }

    @Test("the lease refuses to overwrite commits that weren't fetched, and the rewrite stays recorded")
    func leaseRefusesUnfetchedCommits() async throws {
        let (fixture, amended) = try await makeRewrittenRepository()
        let theirs = try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])
        }
        #expect(error?.gitFailure?.stderr.contains("stale info") == true)
        let retry = try #require(error?.retry as? PushRetry)
        #expect(retry.request == PushRequest(forceWithLease: true))
        #expect(retry.confirmed == [.forcePush])
        #expect(try await fixture.remoteTip("main") == theirs)
        #expect(try await fixture.head() == amended)
        #expect(fixture.model.operations.rewrittenBranches["main"] == amended)
        await fixture.app.idle()
    }

    @Test("retrying a failed force push force pushes again (desktop's retry pushed without force)")
    func retryKeepsOptions() async throws {
        let (fixture, amended) = try await makeRewrittenRepository()
        let preReceive = POSIXPath.join(fixture.remote.path, "hooks", "pre-receive")
        try writeScript(preReceive, "#!/bin/sh\necho 'not now' >&2\nexit 1\n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])
        }
        #expect(error?.gitFailure?.stderr.contains("pre-receive hook declined") == true)
        #expect(fixture.model.operations.rewrittenBranches["main"] == amended)
        let retry = try #require(error?.retry)

        try FileManager.default.removeItem(atPath: preReceive)
        try await retry.perform(in: fixture.app)

        #expect(try await fixture.remoteTip("main") == amended)
        #expect(fixture.model.operations.rewrittenBranches["main"] == nil)
        await fixture.app.idle()
    }

    // MARK: Rejections and failures

    @Test("a push rejected for newer commits on the remote offers Fetch; fetching, pulling, and pushing again succeeds")
    func rejected() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "mine.txt", "mine\n")
        }
        try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push()
        }
        #expect(error?.reason == .pushRejectedNonFastForward)
        #expect((error?.retry as? PushRetry)?.request == PushRequest())
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .fetch)
        #expect(error?.recoveries.count == 1)

        try await recovery.perform(in: fixture.app)
        guard case .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 1), tagsToPush: 0, withRebase: false, forcePushAvailable: true) = fixture.model.sync.action else {
            Issue.record("Unexpected action \(fixture.model.sync.action)")
            return
        }
        #expect(try await fixture.model.sync.pull() == .completed)
        _ = try await fixture.model.sync.push()
        #expect(try await fixture.remoteTip("main") == (try await fixture.head()))
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        await fixture.app.idle()
    }

    @Test("pushing to a GitHub repository without write access offers a fork when an account matches")
    func insufficientPermissions() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        // The remote answers as GitHub does when the account can't push.
        try writeScript(
            POSIXPath.join(fixture.remote.path, "hooks", "pre-receive"),
            "#!/bin/sh\necho 'fatal: Authentication failed' >&2\nexit 1\n"
        )
        fixture.associate(ModelFixtures.gitHubRepository(owner: "octocat", name: "app", permissions: .read))

        var error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push()
        }
        #expect(error?.reason == .insufficientPermissions(repositoryFullName: "octocat/app"))
        #expect(error?.recoveries.isEmpty == true)

        try await fixture.harness.signIn([testAccount], to: fixture.app)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push()
        }
        #expect(error?.recoveries.map(\.kind) == [.createFork])
        await fixture.app.idle()
    }

    @Test("the fetch after a push failing doesn't fail the push, and comes back as the fetch's error")
    func fetchAfterPushFails() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "a.txt", "a\n")
            // Fetching runs upload-pack, which fails; pushing runs
            // receive-pack.
            try await runGit(["config", "remote.origin.uploadpack", "false"], local)
        }

        let outcome = try await fixture.model.sync.push()

        guard case .pushed("main", "origin", [], let fetchFailure?) = outcome else {
            Issue.record("Unexpected outcome \(outcome)")
            return
        }
        #expect(fetchFailure.operation == .fetch)
        #expect(fetchFailure.retry?.kind == .fetch)
        #expect(try await fixture.remoteTip("main") == (try await fixture.head()))
        await fixture.app.idle()
    }

    @Test("a repository without a remote must be published first")
    func noRemote() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "remove", "origin"], local)
        }
        let passes = fixture.model.refreshScheduler.passCount
        #expect(fixture.model.sync.action == .publishRepository)
        #expect(try await fixture.model.sync.push() == .publishRepositoryRequired)
        #expect(try await fixture.model.sync.publishBranch() == .publishRepositoryRequired)
        #expect(fixture.model.refreshScheduler.passCount == passes)
        await fixture.app.idle()
    }

    @Test("needs a branch; force pushing needs an upstream")
    func preconditions() async throws {
        let fixture = try await makeSelectedRepository()

        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        var error = await #expect(throws: OperationError.self) { try await fixture.model.sync.push() }
        #expect(preconditionMessage(error) != nil)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])
        }
        #expect(preconditionMessage(error) != nil)

        try await runGit(["checkout", "-q", "--orphan", "fresh"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        error = await #expect(throws: OperationError.self) { try await fixture.model.sync.push() }
        #expect(preconditionMessage(error) != nil)

        try await runGit(["checkout", "-q", "-b", "local-only", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(PushRequest(forceWithLease: true))
        }
        #expect(preconditionMessage(error) != nil)
        await fixture.app.idle()
    }

    // MARK: Hooks

    @Test("a failing pre-push hook asks: Abort cancels and keeps the tags queued, Ignore pushes")
    func prePushHook() async throws {
        try await withWiredHooks { runtime in
            let fixture = try await makeSelectedRepository(
                responder: PromptResponder.answering([.hookFailure(.abort), .hookFailure(.ignore)]),
                git: runtime
            ) { local in
                try await commitFile(local, "a.txt", "a\n")
            }
            try writeScript(fixture.local.path + "/.git/hooks/pre-push", "#!/bin/sh\necho 'tests failed' >&2\nexit 1\n")
            try await fixture.model.branches.createTag("v1.0", at: try await fixture.head())
            let remoteTip = try await fixture.remoteTip("main")

            let error = await #expect(throws: OperationError.self) {
                try await fixture.model.sync.push()
            }
            #expect(error?.reason == .cancelled(.hookAborted("pre-push")))
            #expect(try await fixture.remoteTip("main") == remoteTip)
            #expect(fixture.model.branches.tagsToPush == ["v1.0"])

            #expect(try await fixture.model.sync.push() == .pushed(branch: "main", remote: "origin", tags: ["v1.0"], fetchFailure: nil))
            #expect(try await fixture.remoteTip("main") == (try await fixture.head()))
            #expect(fixture.model.branches.tagsToPush.isEmpty)
            #expect(fixture.harness.prompts.history.count == 2)
            for prompt in fixture.harness.prompts.history {
                guard case .hookFailed(let name, let output) = prompt else {
                    Issue.record("Unexpected prompt \(prompt)")
                    continue
                }
                #expect(name == "pre-push")
                #expect(output.contains("tests failed"))
            }
            await fixture.app.idle()
        }
    }
}

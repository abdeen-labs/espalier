// These drive `SyncModel.push` against several local bare remotes: the
// remotes a push also goes to, one that refuses and its Retry, the branch's
// own remote refusing, tags, a force push's lease on each remote, a branch
// that tracks a marked remote, Espalier's fork remotes, and choosing the
// remote a branch is published to.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Push destinations", .offline) @MainActor
struct PushDestinationsTests {
    /// A selected repository with `origin` and the bare remotes named
    /// `names`, each at `main`'s first commit, those in `marked` made ones a
    /// push also goes to. Returns the remotes by name.
    private func makeRepository(
        remotes names: [String] = ["mirror"],
        marked: [String] = ["mirror"],
        _ prepare: (Repository) async throws -> Void = { _ in }
    ) async throws -> (fixture: SelectedRepository, remotes: [String: Repository]) {
        var remotes: [String: Repository] = [:]
        for name in names {
            // Its HEAD names `main`, so a clone of it commits there.
            let remote = try await makeEmptyBareRemote()
            try await runGit(["symbolic-ref", "HEAD", "refs/heads/main"], remote)
            remotes[name] = remote
        }
        let fixture = try await makeSelectedRepository { local in
            for name in names {
                try await runGit(["remote", "add", name, try #require(remotes[name]).path], local)
                try await runGit(["push", "-q", name, "main"], local)
            }
            try await prepare(local)
        }
        for name in marked {
            try await fixture.model.sync.setPushDestination(name, true)
        }
        return (fixture, remotes)
    }

    /// The commit `ref` names in `remote`, or nil.
    private func tip(_ ref: String, in remote: Repository?) async throws -> String? {
        try await resolveRef(ref, in: try #require(remote))
    }

    /// A `pre-receive` hook in `remote` that refuses every push. Returns its
    /// path, to remove.
    private func refusePushes(to remote: Repository?) throws -> String {
        let hook = POSIXPath.join(try #require(remote).path, "hooks", "pre-receive")
        try writeScript(hook, "#!/bin/sh\necho 'not now' >&2\nexit 1\n")
        return hook
    }

    // MARK: Choosing the remotes

    @Test("a remote is made one a push also goes to, and no longer one; one the repository doesn't have isn't")
    func choosing() async throws {
        let (fixture, _) = try await makeRepository(remotes: ["mirror", "backup"], marked: [])
        let remotes = { fixture.model.gitState.remotes }
        #expect(remotes().otherPushRemotes.map(\.name) == ["backup", "mirror"])
        #expect(remotes().additionalPushRemotes.isEmpty)

        try await fixture.model.sync.setPushDestination("mirror", true)
        #expect(remotes().additionalPushRemotes.map(\.name) == ["mirror"])
        #expect(try await getPushDestinationNames(fixture.local) == ["mirror"].exactSet)

        try await fixture.model.sync.setPushDestination("mirror", false)
        #expect(remotes().additionalPushRemotes.isEmpty)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.setPushDestination("gone", true)
        }
        #expect(preconditionMessage(error) != nil)
        #expect(try await getPushDestinationNames(fixture.local).isEmpty)
        await fixture.app.idle()
    }

    // MARK: Pushing

    @Test("a push also goes to the marked remotes, in order, and not to the others; the branch keeps its upstream")
    func pushesToMarkedRemotes() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["archive", "backup", "mirror"], marked: ["mirror", "archive"]) { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        let seed = try await fixture.localSHA("HEAD~1")
        let head = try await fixture.head()

        let outcome = try await fixture.model.sync.push()

        #expect(outcome == .pushed(
            branch: "main",
            remote: "origin",
            tags: [],
            fetchFailure: nil,
            additional: [AdditionalPush(remote: "archive"), AdditionalPush(remote: "mirror")]
        ))
        #expect(try await fixture.remoteTip("main") == head)
        #expect(try await tip("refs/heads/main", in: remotes["archive"]) == head)
        #expect(try await tip("refs/heads/main", in: remotes["mirror"]) == head)
        #expect(try await tip("refs/heads/main", in: remotes["backup"]) == seed)
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/main")
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        await fixture.app.idle()
    }

    @Test("a remote that refuses doesn't stop the others; its Retry pushes to it alone")
    func refusingRemote() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["archive", "mirror"], marked: ["archive", "mirror"]) { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        let seed = try await fixture.localSHA("HEAD~1")
        let head = try await fixture.head()
        let hook = try refusePushes(to: remotes["archive"])

        let outcome = try await fixture.model.sync.push()

        guard case .pushed("main", "origin", [], nil, let additional) = outcome else {
            Issue.record("Unexpected outcome \(outcome)")
            return
        }
        #expect(additional.map(\.remote) == ["archive", "mirror"])
        let failure = try #require(additional.first?.failure)
        #expect(failure.gitFailure?.stderr.contains("pre-receive hook declined") == true)
        #expect(additional.last?.failure == nil)
        #expect(try await fixture.remoteTip("main") == head)
        #expect(try await tip("refs/heads/main", in: remotes["archive"]) == seed)
        #expect(try await tip("refs/heads/main", in: remotes["mirror"]) == head)

        let retry = try #require(failure.retry as? PushRetry)
        #expect(retry.request == PushRequest(branch: "refs/heads/main", onlyRemote: "archive"))

        // The Retry reaches only the remote that refused: the others refuse
        // now, and nothing is asked of them.
        let others = [try refusePushes(to: fixture.remote), try refusePushes(to: remotes["mirror"])]
        try FileManager.default.removeItem(atPath: hook)
        let retried = try await retry.perform(in: fixture.app)

        #expect(retried == .push(.pushed(branch: "main", remote: "archive", tags: [], fetchFailure: nil), repositoryID: fixture.model.id))
        #expect(try await tip("refs/heads/main", in: remotes["archive"]) == head)
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/main")
        for other in others {
            try FileManager.default.removeItem(atPath: other)
        }
        await fixture.app.idle()
    }

    @Test("when the branch's own remote refuses, nothing goes to the others")
    func ownRemoteRefuses() async throws {
        let (fixture, remotes) = try await makeRepository { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        let seed = try await fixture.localSHA("HEAD~1")
        let theirs = try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push()
        }

        #expect(error?.reason == .pushRejectedNonFastForward)
        #expect(try await fixture.remoteTip("main") == theirs)
        #expect(try await tip("refs/heads/main", in: remotes["mirror"]) == seed)
        await fixture.app.idle()
    }

    @Test("the queued tags go to the other remotes too, and with a Retry to one that refused")
    func tags() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["archive", "mirror"], marked: ["archive", "mirror"]) { local in
            try await commitFile(local, "a.txt", "a\n")
            try await runGit(["tag", "v1"], local)
        }
        let head = try await fixture.head()
        fixture.app.updateRecord(fixture.model.id) { $0.tagsToPush = ["v1"] }
        let hook = try refusePushes(to: remotes["archive"])

        let outcome = try await fixture.model.sync.push()

        guard case .pushed("main", "origin", ["v1"], nil, let additional) = outcome else {
            Issue.record("Unexpected outcome \(outcome)")
            return
        }
        #expect(try await fixture.remoteTip("refs/tags/v1") == nil)
        #expect(try await resolveRef("refs/tags/v1", in: fixture.remote) == head)
        #expect(try await tip("refs/tags/v1", in: remotes["mirror"]) == head)
        #expect(try await tip("refs/tags/v1", in: remotes["archive"]) == nil)
        #expect(fixture.model.record.tagsToPush.isEmpty)

        let retry = try #require(additional.first?.failure?.retry as? PushRetry)
        #expect(retry.request == PushRequest(branch: "refs/heads/main", onlyRemote: "archive", onlyRemoteTags: ["v1"]))
        try FileManager.default.removeItem(atPath: hook)
        try await retry.perform(in: fixture.app)

        #expect(try await tip("refs/tags/v1", in: remotes["archive"]) == head)
        await fixture.app.idle()
    }

    @Test("a branch being published goes to the other remotes under its name, and tracks only its own")
    func publishing() async throws {
        let (fixture, remotes) = try await makeRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        let head = try await fixture.head()

        let outcome = try await fixture.model.sync.publishBranch()

        #expect(outcome == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil, additional: [AdditionalPush(remote: "mirror")]))
        #expect(try await fixture.remoteTip("feature") == head)
        #expect(try await tip("refs/heads/feature", in: remotes["mirror"]) == head)
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/feature")
        #expect(try await runGit(["config", "branch.feature.remote"], fixture.local) == "origin\n")
        await fixture.app.idle()
    }

    @Test("a branch tracking a branch of another name goes to that name on the other remotes")
    func upstreamOfAnotherName() async throws {
        let (fixture, remotes) = try await makeRepository { local in
            try await runGit(["checkout", "-q", "-b", "topic", "--track", "origin/main"], local)
            try await commitFile(local, "topic.txt", "topic\n")
        }
        let head = try await fixture.head()

        _ = try await fixture.model.sync.push()

        #expect(try await fixture.remoteTip("main") == head)
        #expect(try await tip("refs/heads/main", in: remotes["mirror"]) == head)
        #expect(try await tip("refs/heads/topic", in: remotes["mirror"]) == nil)
        await fixture.app.idle()
    }

    @Test("a branch that tracks a marked remote is pushed there once, then to the other marked remotes")
    func tracksMarkedRemote() async throws {
        let (fixture, remotes) = try await makeRepository(marked: []) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["push", "-q", "-u", "mirror", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        try await fixture.model.sync.setPushDestination("mirror", true)
        try await fixture.model.sync.setPushDestination("origin", true)
        let head = try await fixture.head()
        #expect(fixture.model.gitState.remotes.additionalPushRemotes.map(\.name) == ["origin"])

        let outcome = try await fixture.model.sync.push()

        #expect(outcome == .pushed(branch: "feature", remote: "mirror", tags: [], fetchFailure: nil, additional: [AdditionalPush(remote: "origin")]))
        #expect(try await tip("refs/heads/feature", in: remotes["mirror"]) == head)
        #expect(try await fixture.remoteTip("feature") == head)
        #expect(fixture.model.gitState.tip.branch?.upstream == "mirror/feature")
        await fixture.app.idle()
    }

    @Test("a fork remote Espalier added takes no push, marked or not")
    func forkRemote() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["espalier-octocat"], marked: []) { local in
            try await markForkRemote(local, "espalier-octocat")
            try await setPushDestination(local, "espalier-octocat", true)
            try await commitFile(local, "a.txt", "a\n")
        }
        let seed = try await fixture.localSHA("HEAD~1")
        #expect(fixture.model.gitState.remotes.otherPushRemotes.isEmpty)

        #expect(try await fixture.model.sync.push() == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await tip("refs/heads/main", in: remotes["espalier-octocat"]) == seed)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.setPushDestination("espalier-octocat", true)
        }
        #expect(preconditionMessage(error) != nil)
        await fixture.app.idle()
    }

    // MARK: Force pushes

    /// A repository whose `main` was pushed to `origin` and `mirror` with a
    /// commit on top of the seed and fetched from both, then amended, with
    /// the rewrite recorded as an amend records it. Returns the commit
    /// pushed and the amended one.
    private func makeRewrittenRepository() async throws -> (fixture: SelectedRepository, mirror: Repository, pushed: String, amended: String) {
        let (fixture, remotes) = try await makeRepository { local in
            try await commitFile(local, "a.txt", "a\n", message: "Add a")
            try await runGit(["push", "-q", "origin", "main"], local)
            try await runGit(["push", "-q", "mirror", "main"], local)
        }
        let pushed = try await fixture.head()
        try await runGit(["commit", "-q", "--amend", "-m", "Add a (amended)"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let branch = try #require(fixture.model.gitState.tip.branch)
        await fixture.model.operations.recordRewrite(of: branch, previousTip: pushed, upstreamTip: pushed)
        return (fixture, try #require(remotes["mirror"]), pushed, try await fixture.head())
    }

    @Test("a force push overwrites the branch on the other remotes too")
    func forcePush() async throws {
        let (fixture, mirror, _, amended) = try await makeRewrittenRepository()

        let outcome = try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])

        #expect(outcome == .pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil, additional: [AdditionalPush(remote: "mirror")]))
        #expect(try await fixture.remoteTip("main") == amended)
        #expect(try await resolveRef("refs/heads/main", in: mirror) == amended)
        await fixture.app.idle()
    }

    @Test("a force push's lease on another remote refuses commits that weren't fetched from it; its Retry forces again")
    func forcePushLease() async throws {
        let (fixture, mirror, _, amended) = try await makeRewrittenRepository()
        let theirs = try await pushCommitFromAnotherClone(mirror, path: "theirs.txt", contents: "theirs\n")

        let outcome = try await fixture.model.sync.push(PushRequest(forceWithLease: true), confirmed: [.forcePush])

        guard case .pushed("main", "origin", [], nil, let additional) = outcome else {
            Issue.record("Unexpected outcome \(outcome)")
            return
        }
        #expect(try await fixture.remoteTip("main") == amended)
        #expect(try await resolveRef("refs/heads/main", in: mirror) == theirs)
        let failure = try #require(additional.first?.failure)
        #expect(failure.gitFailure?.stderr.contains("stale info") == true)
        let retry = try #require(failure.retry as? PushRetry)
        #expect(retry.request == PushRequest(forceWithLease: true, branch: "refs/heads/main", onlyRemote: "mirror"))
        #expect(retry.confirmed == [.forcePush])

        // Fetched, their commit is one the lease knows: the Retry overwrites
        // it, as the force push the user confirmed does on the branch's own
        // remote.
        try await fixture.model.sync.fetch()
        try await retry.perform(in: fixture.app)
        #expect(try await resolveRef("refs/heads/main", in: mirror) == amended)
        await fixture.app.idle()
    }

    // MARK: Retrying

    @Test("a Retry for one remote pushes nothing once another branch is current, or the remote is gone")
    func retryPreconditions() async throws {
        let (fixture, remotes) = try await makeRepository { local in
            try await commitFile(local, "a.txt", "a\n")
            try await runGit(["branch", "other"], local)
        }
        let seed = try await fixture.localSHA("HEAD~1")
        let request = PushRequest(branch: "refs/heads/main", onlyRemote: "mirror")

        try await runGit(["checkout", "-q", "other"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        var error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(request)
        }
        #expect(preconditionMessage(error) != nil)

        try await runGit(["checkout", "-q", "main"], fixture.local)
        try await fixture.model.sync.removeRemote("mirror")
        error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push(request)
        }
        #expect(preconditionMessage(error) != nil)
        #expect(try await tip("refs/heads/main", in: remotes["mirror"]) == seed)
        await fixture.app.idle()
    }

    // MARK: Publishing to a remote of the user's choice

    @Test("publishing a branch that tracks no remote asks which, the current one first, and pushes nothing")
    func publishAsks() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["archive", "mirror"], marked: []) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.publishBranch(choosing: nil)
        }

        guard case .decisionRequired(.publishRemote("feature", let asked))? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(asked.map(\.name) == ["origin", "archive", "mirror"])
        #expect(asked.map(\.url) == [fixture.remote.path, try #require(remotes["archive"]).path, try #require(remotes["mirror"]).path])
        #expect(try await fixture.remoteTip("feature") == nil)
        #expect(try await tip("refs/heads/feature", in: remotes["mirror"]) == nil)
        await fixture.app.idle()
    }

    @Test("the branch is published to the remote chosen, which it tracks, and to the marked ones")
    func publishToChosenRemote() async throws {
        let (fixture, remotes) = try await makeRepository(remotes: ["archive", "mirror"], marked: ["mirror", "archive"]) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        let head = try await fixture.head()

        let outcome = try await fixture.model.sync.publishBranch(choosing: "mirror")

        #expect(outcome == .pushed(branch: "feature", remote: "mirror", tags: [], fetchFailure: nil, additional: [AdditionalPush(remote: "archive")]))
        #expect(try await tip("refs/heads/feature", in: remotes["mirror"]) == head)
        #expect(try await tip("refs/heads/feature", in: remotes["archive"]) == head)
        #expect(try await fixture.remoteTip("feature") == nil)
        #expect(fixture.model.gitState.tip.branch?.upstream == "mirror/feature")
        #expect(fixture.model.sync.action == .fetch(remote: "mirror"))
        await fixture.app.idle()
    }

    @Test("nothing is asked with one remote, of a branch that tracks one, or without the choice offered")
    func publishWithoutAsking() async throws {
        // One remote.
        let single = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        #expect(try await single.model.sync.publishBranch(choosing: nil) == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil))
        await single.app.idle()

        // Several, and a branch whose remote branch is gone: it's pushed to
        // the remote it tracks.
        let (tracking, remotes) = try await makeRepository(marked: []) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
            try await runGit(["push", "-q", "-u", "mirror", "feature"], local)
            try await runGit(["push", "-q", "mirror", "--delete", "feature"], local)
        }
        #expect(tracking.model.sync.action == .publishBranch(remote: "mirror", isGitHubRepository: false))
        #expect(try await tracking.model.sync.publishBranch(choosing: nil) == .pushed(branch: "feature", remote: "mirror", tags: [], fetchFailure: nil))
        #expect(try await tip("refs/heads/feature", in: remotes["mirror"]) == (try await tracking.head()))
        await tracking.app.idle()

        // Several, published where no choice is offered (creating a pull
        // request): the current remote.
        let (plain, _) = try await makeRepository(marked: []) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        #expect(try await plain.model.sync.publishBranch() == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil))
        await plain.app.idle()
    }

    @Test("a remote chosen that's gone publishes nothing")
    func publishToGoneRemote() async throws {
        let (fixture, _) = try await makeRepository(marked: []) { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.publishBranch(choosing: "gone")
        }

        #expect(preconditionMessage(error) != nil)
        #expect(try await fixture.remoteTip("feature") == nil)
        await fixture.app.idle()
    }
}

// These drive `AppModel.pushWork` and `AppModel.pushAll` against local bare
// remotes: a linked worktree's branch and the record's own, in a selected
// repository and one that isn't; what can't be pushed; Push All's
// confirmation, its skips (unpublished, up to date, behind), a failure that
// doesn't stop the rest, two worktrees of one repository, and a failing
// pre-push hook that's skipped without asking.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Home: pushing work", .offline) @MainActor
struct WorkPushTests {
    /// A fixture with `feature` published and checked out in a linked
    /// worktree, which has a commit to push, and a file changed there.
    private func makeLinkedFeature(selected: Bool, git: GitRuntime? = nil) async throws -> (WorkFixture, path: String, tip: String) {
        let fixture = try await WorkFixture.make(selected: selected, git: git) { local in
            try await makePublishedBranch("feature", in: local)
        }
        let path = try await fixture.addWorktree("feature-tree", branch: "feature")
        let tip = try await commitFile(Repository(path: path), "more.txt", "more\n")
        try Data("changed\n".utf8).write(to: URL(filePath: POSIXPath.join(path, "feature.txt")))
        return (fixture, path, tip)
    }

    // MARK: One worktree

    @Test("pushes a linked worktree's branch in any repository, leaving the record and the working tree as they are", arguments: [false, true])
    func pushesLinkedWorktree(selected: Bool) async throws {
        let (fixture, path, tip) = try await makeLinkedFeature(selected: selected)
        let recordPath = fixture.model.record.path
        let selection = fixture.app.selection

        let outcome = try await fixture.app.pushWork(fixture.key(path))

        #expect(outcome == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await fixture.remoteTip("feature") == tip)
        #expect(try await fixture.localSHA("refs/remotes/origin/feature") == tip)
        #expect(fixture.model.record.path == recordPath)
        #expect(fixture.app.selection == selection)
        #expect(try String(contentsOfFile: POSIXPath.join(path, "feature.txt"), encoding: .utf8) == "changed\n")
        #expect(try await runGit(["status", "--porcelain"], Repository(path: path)) == " M feature.txt\n")
        await fixture.app.idle()
    }

    @Test("pushes the branch of the worktree the record points at")
    func pushesRecordsWorktree() async throws {
        let fixture = try await WorkFixture.make(selected: false) { local in
            try await makePublishedBranch("feature", in: local)
            try await runGit(["checkout", "-q", "feature"], local)
            try await commitFile(local, "more.txt", "more\n")
        }
        let tip = try #require(try await fixture.localSHA("HEAD"))

        let outcome = try await fixture.app.pushWork(fixture.key(fixture.local.path))

        #expect(outcome == .pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil))
        #expect(try await fixture.remoteTip("feature") == tip)
        await fixture.app.idle()
    }

    /// Worktrees whose branches can't be pushed here.
    enum Unpushable: String, CaseIterable, CustomTestStringConvertible {
        case notPublished, detached, folderGone, notAWorktree

        var testDescription: String {
            rawValue
        }
    }

    @Test("refuses a worktree whose branch can't be pushed, pushing nothing", arguments: Unpushable.allCases)
    func refuses(_ unpushable: Unpushable) async throws {
        let fixture = try await WorkFixture.make(selected: false) { local in
            try await runGit(["branch", "local-only", "main"], local)
        }
        let path: String
        switch unpushable {
        case .notPublished:
            path = try await fixture.addWorktree("tree", branch: "local-only")
            try await commitFile(Repository(path: path), "a.txt", "a\n")
        case .detached:
            path = POSIXPath.join(fixture.directory, "tree")
            try await runGit(["worktree", "add", "-q", "--detach", path, "main"], fixture.local)
        case .folderGone:
            path = try await fixture.addWorktree("tree", branch: "local-only")
            try FileManager.default.removeItem(atPath: path)
        case .notAWorktree:
            // Another repository's folder.
            path = try setupEmptyRepository().path
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.app.pushWork(fixture.key(path))
        }
        #expect(preconditionMessage(error) != nil)
        #expect(try await fixture.remoteTip("local-only") == nil)
        #expect(try await localBranchNames(fixture.remote) == ["main"])
        await fixture.app.idle()
    }

    // MARK: Push All

    @Test("Push All asks first, naming what it pushes with commit counts, then pushes each and says what it skipped")
    func pushAllConfirmsThenPushes() async throws {
        let fixture = try await WorkFixture.make(selected: false) { local in
            try await makePublishedBranch("ahead", in: local, file: "ahead.txt")
            try await makePublishedBranch("current", in: local, file: "current.txt")
            try await runGit(["branch", "unpublished", "main"], local)
        }
        let ahead = try await fixture.addWorktree("ahead-tree", branch: "ahead")
        try await commitFile(Repository(path: ahead), "1.txt", "1\n")
        let aheadTip = try await commitFile(Repository(path: ahead), "2.txt", "2\n")
        let current = try await fixture.addWorktree("current-tree", branch: "current")
        let unpublished = try await fixture.addWorktree("unpublished-tree", branch: "unpublished")
        try await commitFile(Repository(path: unpublished), "u.txt", "u\n")
        // A second repository, the selected one, with its own branch ahead.
        let otherModel = try #require(fixture.app.selectedRepository)
        let otherLocal = otherModel.gitRepository
        try await commitFile(otherLocal, "other.txt", "other\n")
        let otherTip = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], otherLocal))
        let keys = [
            fixture.key(ahead),
            fixture.key(current),
            fixture.key(unpublished),
            WorktreeKey(repositoryID: otherModel.id, path: otherLocal.path),
        ]

        let error = await #expect(throws: OperationError.self) {
            try await fixture.app.pushAll(keys)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .pushAll)
        #expect(confirmation.details == .pushes([
            BranchPush(worktree: keys[0], repository: fixture.model.record.displayName, branch: "ahead", commits: 2),
            BranchPush(worktree: keys[3], repository: otherModel.record.displayName, branch: "main", commits: 1),
        ]))
        #expect(try await fixture.remoteTip("ahead") != aheadTip)

        let result = try await fixture.app.pushAll(keys, confirmed: [.pushAll])

        #expect(result.items.map(\.worktree) == keys)
        #expect(result.items.map(\.branch) == ["ahead", "current", "unpublished", "main"])
        #expect(result.items.map(\.outcome) == [
            .pushed(.pushed(branch: "ahead", remote: "origin", tags: [], fetchFailure: nil)),
            .skipped(.upToDate),
            .skipped(.notPublished),
            .pushed(.pushed(branch: "main", remote: "origin", tags: [], fetchFailure: nil)),
        ])
        #expect(try await fixture.remoteTip("ahead") == aheadTip)
        #expect(try await fixture.remoteTip("unpublished") == nil)
        #expect(JSCompat.trim(try await runGit(["rev-parse", "origin/main"], otherLocal)) == otherTip)
        await fixture.app.idle()
    }

    @Test("Push All skips a branch behind its upstream as needing a pull, without pushing it")
    func pushAllSkipsBehind() async throws {
        let fixture = try await WorkFixture.make(selected: true) { local in
            try await makePublishedBranch("feature", in: local)
        }
        let path = try await fixture.addWorktree("feature-tree", branch: "feature")
        try await commitFile(Repository(path: path), "mine.txt", "mine\n")
        let clone = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "feature"], clone)
        let theirs = try await commitFile(clone, "theirs.txt", "theirs\n")
        try await runGit(["push", "-q", "origin", "feature"], clone)
        try await runGit(["fetch", "-q", "origin"], fixture.local)

        let result = try await fixture.app.pushAll([fixture.key(path)], confirmed: [.pushAll])

        #expect(result.items.map(\.outcome) == [.skipped(.needsPull)])
        #expect(try await fixture.remoteTip("feature") == theirs)
        await fixture.app.idle()
    }

    @Test("Push All with nothing to push asks nothing")
    func pushAllNothingToPush() async throws {
        let fixture = try await WorkFixture.make(selected: true)

        let result = try await fixture.app.pushAll([fixture.key(fixture.local.path)])

        #expect(result.items.map(\.outcome) == [.skipped(.upToDate)])
    }

    @Test("Push All goes on after a push fails, and pushes two worktrees of one repository")
    func pushAllFailureDoesNotStopOthers() async throws {
        let fixture = try await WorkFixture.make(selected: false) { local in
            try await makePublishedBranch("one", in: local, file: "one.txt")
            try await makePublishedBranch("two", in: local, file: "two.txt")
        }
        let one = try await fixture.addWorktree("one-tree", branch: "one")
        let oneTip = try await commitFile(Repository(path: one), "1.txt", "1\n")
        let two = try await fixture.addWorktree("two-tree", branch: "two")
        let twoTip = try await commitFile(Repository(path: two), "2.txt", "2\n")
        // The selected repository's remote refuses every push.
        let otherModel = try #require(fixture.app.selectedRepository)
        let otherLocal = otherModel.gitRepository
        try await commitFile(otherLocal, "other.txt", "other\n")
        let otherRemote = JSCompat.trim(try await runGit(["remote", "get-url", "origin"], otherLocal))
        try writeScript(POSIXPath.join(otherRemote, "hooks/pre-receive"), "#!/bin/sh\necho 'no pushes' >&2\nexit 1\n")
        let keys = [WorktreeKey(repositoryID: otherModel.id, path: otherLocal.path), fixture.key(one), fixture.key(two)]

        let result = try await fixture.app.pushAll(keys, confirmed: [.pushAll])

        guard case .failed(let error) = result.items[0].outcome else {
            Issue.record("Expected a failure, got \(result.items[0].outcome)")
            return
        }
        #expect(error.repositoryID == otherModel.id)
        #expect(result.items[1].outcome == .pushed(.pushed(branch: "one", remote: "origin", tags: [], fetchFailure: nil)))
        #expect(result.items[2].outcome == .pushed(.pushed(branch: "two", remote: "origin", tags: [], fetchFailure: nil)))
        #expect(try await fixture.remoteTip("one") == oneTip)
        #expect(try await fixture.remoteTip("two") == twoTip)
        await fixture.app.idle()
    }

    @Test("Push All skips a push whose pre-push hook fails, without asking, and pushes the others")
    func pushAllSkipsFailingHook() async throws {
        try await withWiredHooks { runtime in
            let fixture = try await WorkFixture.make(selected: false, git: runtime) { local in
                try await makePublishedBranch("feature", in: local)
            }
            let path = try await fixture.addWorktree("feature-tree", branch: "feature")
            let tip = try await commitFile(Repository(path: path), "more.txt", "more\n")
            let otherModel = try #require(fixture.app.selectedRepository)
            let otherLocal = otherModel.gitRepository
            try await commitFile(otherLocal, "other.txt", "other\n")
            try writeScript(POSIXPath.join(otherLocal.path, ".git/hooks/pre-push"), "#!/bin/sh\necho 'tests failed' >&2\nexit 1\n")
            let keys = [WorktreeKey(repositoryID: otherModel.id, path: otherLocal.path), fixture.key(path)]

            let result = try await fixture.app.pushAll(keys, confirmed: [.pushAll])

            guard case .skipped(.needsUser(let error)) = result.items[0].outcome else {
                Issue.record("Expected a skip, got \(result.items[0].outcome)")
                return
            }
            #expect(error.reason == .cancelled(.hookAborted("pre-push")))
            #expect(result.items[1].outcome == .pushed(.pushed(branch: "feature", remote: "origin", tags: [], fetchFailure: nil)))
            #expect(try await fixture.remoteTip("feature") == tip)
            #expect(fixture.harness.prompts.history.isEmpty)
            await fixture.app.idle()
        }
    }
}

// These drive the sync button's Stop (`SyncModel.stop()`) against local
// bare remotes whose upload-pack or receive-pack waits in a script, as a
// stalled network would: not offered before `SyncModel.stopDelay`, then a
// fetch (the user's or a background one), a push, and a pull that fetches
// end as cancellations with git's processes gone; a running hook is
// aborted. And a pull while a merge or rebase waits on its conflicts is
// refused before git runs.

import Darwin
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Sync: Stop", .offline) @MainActor
struct SyncStopTests {
    /// Makes the clone's `origin` run `command` (`uploadpack` for fetches,
    /// `receivepack` for pushes) through a script that waits at a gate
    /// until released, then runs git's own.
    private func makeGate(_ command: String, of clone: Repository) async throws -> ProcessGate {
        let gate = try ProcessGate()
        let script = POSIXPath.join(gate.directory, command)
        let program = command == "receivepack" ? "git-receive-pack" : "git-upload-pack"
        try gate.writeScript(script, """
            #!/bin/sh
            \(gate.waitLines)
            exec \(program) "$@"
            """)
        try await runGit(["config", "remote.origin.\(command)", script], clone)
        return gate
    }

    @Test("Stop isn't offered before 10 seconds; then it ends a fetch as a cancellation, with git's processes gone and no failure badge", .hangGuard(minutes: 5), arguments: [
        NamedCase("a fetch the user started", false),
        NamedCase("a background fetch", true),
    ])
    func stopsFetch(_ testCase: NamedCase<Bool>) async throws {
        let isBackground = testCase.value
        let fixture = try await makeSelectedRepository()
        try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")
        let tracking = try await fixture.localSHA("refs/remotes/origin/main")
        let gate = try await makeGate("uploadpack", of: fixture.local)
        let sync = fixture.model.sync

        let fetch = Task {
            if isBackground {
                _ = try await sync.backgroundFetch()
            } else {
                try await sync.fetch()
            }
        }
        let held = try await gate.waitUntilHeld(while: fetch)
        defer { Darwin.close(held) }
        #expect(sync.stopOfferedAt != nil)

        await fixture.harness.scheduler.advance(by: .seconds(9))
        #expect(!sync.stop())
        await fixture.harness.scheduler.advance(by: .seconds(1))
        #expect(sync.stop())
        #expect(await gate.waitUntilGone(held))

        let error = await #expect(throws: OperationError.self) { try await fetch.value }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(error?.isCancellation == true)
        #expect(fixture.model.lastBackgroundFailure == nil)
        #expect(try await fixture.localSHA("refs/remotes/origin/main") == tracking)
        #expect(fixture.model.networkOperation == nil)
        #expect(sync.stopOfferedAt == nil)
        await fixture.app.idle()
    }

    @Test("Stop ends a push as a cancellation: nothing pushed, and git's processes gone", .hangGuard(minutes: 5))
    func stopsPush() async throws {
        let fixture = try await makeSelectedRepository()
        let remoteTip = try await fixture.remoteTip("main")
        try await commitFile(fixture.local, "new.txt", "new\n")
        await fixture.model.refresh(.full, reason: .user)
        let gate = try await makeGate("receivepack", of: fixture.local)

        let sync = fixture.model.sync
        let push = Task { try await sync.push() }
        let held = try await gate.waitUntilHeld(while: push)
        defer { Darwin.close(held) }

        await fixture.harness.scheduler.advance(by: .seconds(10))
        #expect(sync.stop())
        #expect(await gate.waitUntilGone(held))

        let error = await #expect(throws: OperationError.self) { try await push.value }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(try await fixture.remoteTip("main") == remoteTip)
        #expect(fixture.model.networkOperation == nil)
        await fixture.app.idle()
    }

    @Test("Stop while a pull fetches ends it before it merges: HEAD, the index, and the working tree as they were", .hangGuard(minutes: 5))
    func stopsPullWhileFetching() async throws {
        let fixture = try await makeSelectedRepository()
        try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")
        // The branch is behind already, so the pull's merge would have work.
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let head = try await fixture.head()
        let gate = try await makeGate("uploadpack", of: fixture.local)

        let sync = fixture.model.sync
        let pull = Task { try await sync.pull() }
        let held = try await gate.waitUntilHeld(while: pull)
        defer { Darwin.close(held) }

        await fixture.harness.scheduler.advance(by: .seconds(10))
        #expect(sync.stop())
        #expect(await gate.waitUntilGone(held))

        let error = await #expect(throws: OperationError.self) { try await pull.value }
        #expect(error?.reason == .cancelled(.userCancelled))
        #expect(try await fixture.head() == head)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "other.txt")))
        for leftover in ["MERGE_HEAD", "index.lock", "rebase-merge"] {
            #expect(!fixture.gitFileExists(leftover), "\(leftover)")
        }
        #expect(try await runGit(["status", "--porcelain"], fixture.local).isEmpty)
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.localOperation == nil)
        await fixture.app.idle()
    }

    @Test("Stop during a pre-push hook aborts the hook: the push ends as a cancellation, nothing pushed", .hangGuard(minutes: 5))
    func abortsHook() async throws {
        try await withWiredHooks { runtime in
            let fixture = try await makeSelectedRepository(git: runtime)
            let remoteTip = try await fixture.remoteTip("main")
            try await commitFile(fixture.local, "new.txt", "new\n")
            try writeScript(fixture.local.path + "/.git/hooks/pre-push", """
                #!/bin/sh
                while :; do sleep 0.05; done
                """)
            await fixture.model.refresh(.full, reason: .user)

            let sync = fixture.model.sync
            let push = Task { try await sync.push() }
            await waitUntilObserved { fixture.model.networkOperation?.hook?.name == "pre-push" }
            await fixture.harness.scheduler.advance(by: .seconds(10))
            #expect(sync.stop())

            let error = await #expect(throws: OperationError.self) { try await push.value }
            #expect(error?.reason == .cancelled(.hookAborted("pre-push")))
            #expect(try await fixture.remoteTip("main") == remoteTip)
            await fixture.app.idle()
        }
    }

    @Test("a pull while a merge or rebase waits on its conflicts is refused before git runs, and the operation keeps waiting", .hangGuard(minutes: 5), arguments: [
        NamedCase("a merge's conflicts", false),
        NamedCase("a rebase's conflicts", true),
    ])
    func pullRefusedDuringConflicts(_ testCase: NamedCase<Bool>) async throws {
        let withRebase = testCase.value
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["push", "-q", "origin", "main"], local)
            if withRebase {
                try await runGit(["config", "pull.rebase", "true"], local)
            }
        }
        let other = try await cloneRepository(fixture.remote)
        try await commitFile(other, "README.md", numberedLinesReplacing(1, with: "theirs"), message: "Theirs")
        try await runGit(["push", "-q", "origin", "main"], other)
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "ours"), message: "Ours")
        await fixture.model.refresh(.full, reason: .user)
        #expect(try await fixture.model.sync.pull() == .conflicted)
        let conflictState = fixture.model.operations.conflictState
        #expect(conflictState != nil)

        // Counts the fetches git would make, letting them through.
        let fetches = try await FetchGate(clone: fixture.local)
        try fetches.open()
        let error = await #expect(throws: OperationError.self) { try await fixture.model.sync.pull() }

        #expect(preconditionMessage(error) != nil)
        #expect(error?.gitFailure == nil)
        #expect(fetches.invocations == 0)
        #expect(fixture.model.operations.conflictState == conflictState)
        #expect(fixture.gitFileExists(withRebase ? "rebase-merge" : "MERGE_HEAD"))
        await fixture.app.idle()
    }
}

// The presenter runs "Clear Old Rebase and Continue" in two steps: the
// rebase's state is cleared once, then the operation runs again.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Clear Old Rebase and Continue", .offline, .hangGuard(minutes: 5)) @MainActor
struct ClearOldRebaseTests {
    @Test("a pull with rebase over a rebase's state Espalier can't continue or abort clears it, then pulls")
    func pull() async throws {
        let fixture = try await makeOperationsFixture { local in
            try await runGit(["config", "pull.rebase", "true"], local)
            try await runGit(["push", "-q", "-u", "origin", "main"], local)
        }
        let other = try await cloneRepository(fixture.remote)
        try await commitFile(other, "theirs.txt", "theirs\n", message: "Theirs")
        try await runGit(["push", "-q", "origin", "main"], other)
        try await commitFile(fixture.local, "ours.txt", "ours\n", message: "Ours")
        try FileManager.default.createDirectory(atPath: POSIXPath.join(fixture.local.path, ".git/rebase-merge"), withIntermediateDirectories: false)
        await fixture.refresh()

        await fixture.presenter.perform { _ throws(OperationError) in
            try await fixture.repository.sync.pull()
        }
        let presented = try #require(fixture.presenter.error)
        guard case .alert(let content, let recoveries) = presented.error.presentation(defaultNumberFormat) else {
            Issue.record("Not an alert: \(presented.error.reason)")
            return
        }
        #expect(content.buttons.map(\.role) == [.primary, .cancel])
        let recovery = try #require(recoveries.first)

        await fixture.presenter.recover(presented.id, with: recovery)
        await fixture.settle()

        #expect(fixture.presenter.error == nil)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git/rebase-merge")))
        #expect(try await fixture.summaries("main") == ["Ours", "Theirs", "Initial commit"])
        #expect(try await fixture.currentBranch() == "main")
    }

    @Test("a squash Espalier refuses over a rebase's state it can't continue or abort clears it, then squashes, with Undo")
    func squash() async throws {
        try await withIsolatedGitConfig { _ in
            var shas: [String: String] = [:]
            let fixture = try await makeOperationsFixture { local in
                for name in ["A", "B"] {
                    shas[name] = try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
                }
            }
            await fixture.loadHistory()
            let a = try #require(shas["A"]), b = try #require(shas["B"])
            // The rebase set changes aside, which clearing it stashes.
            try fixture.harness.write("B.txt", "set aside\n", in: fixture.local)
            let autostash = JSCompat.trim(try await fixture.git(["stash", "create"]))
            try await fixture.git(["reset", "-q", "--hard"])
            let rebaseMerge = POSIXPath.join(fixture.local.path, ".git/rebase-merge")
            try FileManager.default.createDirectory(atPath: rebaseMerge, withIntermediateDirectories: false)
            try Data("\(autostash)\n".utf8).write(to: URL(filePath: POSIXPath.join(rebaseMerge, "autostash")))
            await fixture.refresh()
            // Nothing shows the rebase: the squash is offered.
            #expect(fixture.context.actions.canPerform(.squash(shas: [a, b], into: nil)))
            let plan = try #require(SquashPlan.make(shas: [b, a], into: nil, in: fixture.repository))

            await MultiCommitActions.squash(plan, message: CommitContext(summary: "A and B", description: nil), in: fixture.context)
            let presented = try #require(fixture.presenter.error)
            guard case .alert(let content, let recoveries) = presented.error.presentation(defaultNumberFormat) else {
                Issue.record("Not an alert: \(presented.error.reason)")
                return
            }
            #expect(content.buttons.map(\.role) == [.primary, .cancel])
            #expect(try await fixture.summaries("main") == ["B", "A", "Initial commit"])
            let recovery = try #require(recoveries.first)

            await fixture.presenter.recover(presented.id, with: recovery)
            await fixture.settle()

            #expect(fixture.presenter.error == nil)
            #expect(!FileManager.default.fileExists(atPath: rebaseMerge))
            #expect(try await fixture.git(["stash", "list", "--format=%H %gs"]) == "\(autostash) autostash\n")
            #expect(try await fixture.summaries("main") == ["A and B", "Initial commit"])
            let toast = try #require(fixture.presenter.toasts.last)
            #expect(toast.undo != nil)
        }
    }
}

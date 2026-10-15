// While an operation is in progress, the branch actions the state layer
// refuses are disabled: Switch Branch (⌘B), Check Out (rows, the popover, a
// commit, a pull request), New Branch (the menu and the popover's Create New
// Branch go through its availability), and during a rebase Rename and
// Delete; New Branch's sheet creates nothing.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch actions during operations", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchActionsDuringOperationsTests {
    /// The branch actions' availability, by name.
    private func availability(_ fixture: OperationsFixture) async throws -> [String: Bool] {
        let actions = fixture.context.actions
        let other = try await fixture.sha("other")
        return [
            "switchBranch": actions.canPerform(.switchBranch),
            "newBranch": actions.canPerform(.newBranch(startPoint: nil)),
            "newBranchFromCommit": actions.canPerform(.newBranch(startPoint: other)),
            "checkoutBranch": actions.canPerform(.checkoutBranch(name: "other")),
            "checkoutCommit": actions.canPerform(.checkoutCommit(sha: other)),
            "renameOther": actions.canPerform(.renameBranch(name: "other")),
            "deleteOther": actions.canPerform(.deleteBranch(name: "other")),
            "deleteFeature": actions.canPerform(.deleteBranch(name: "feature")),
        ]
    }

    private let allEnabled = [
        "switchBranch": true, "newBranch": true, "newBranchFromCommit": true, "checkoutBranch": true,
        "checkoutCommit": true, "renameOther": true, "deleteOther": true, "deleteFeature": true,
    ]

    @Test("a merge in progress disables switching and new branches, and deleting the current branch; other branches can be renamed and deleted")
    func merge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            await fixture.loadHistory()
            #expect(try await availability(fixture) == allEnabled)

            // Its conflicts staged: git alone would check out.
            #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
            try fixture.harness.write("README.md", "resolved\n", in: fixture.local)
            try await fixture.git(["add", "README.md"])
            await fixture.refresh()
            #expect(try await availability(fixture) == [
                "switchBranch": false, "newBranch": false, "newBranchFromCommit": false, "checkoutBranch": false,
                "checkoutCommit": false, "renameOther": true, "deleteOther": true, "deleteFeature": false,
            ])

            // New Branch's sheet, already open: refused, nothing created.
            await BranchActions.create("topic", startPoint: .currentBranch, mode: .create, in: fixture.context)
            await fixture.settle()
            let error = try #require(fixture.presenter.error)
            if case .precondition = error.error.reason {} else {
                Issue.record("Not a precondition: \(error.error.reason)")
            }
            #expect(try await fixture.git(["branch", "--list", "topic"]).isEmpty)
            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, ".git", "MERGE_HEAD")))
            fixture.presenter.dismissError(error.id)

            // Aborted, everything is back.
            try await fixture.repository.operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
            await fixture.settle()
            #expect(try await availability(fixture) == allEnabled)
        }
    }

    @Test("a rebase in progress, stopped on conflicts or interrupted, disables every branch change")
    func rebase() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeConflictingFixture()
            await fixture.loadHistory()
            let allDisabled = allEnabled.mapValues { _ in false }

            // Stopped on conflicts, with them staged.
            let operations = fixture.repository.operations
            #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)
            try fixture.harness.write("README.md", "resolved\n", in: fixture.local)
            try await fixture.git(["add", "README.md"])
            await fixture.refresh()
            #expect(try await availability(fixture) == allDisabled)
            // The menu bar's Rename… and Delete… (the current branch): HEAD
            // is detached.
            #expect(!fixture.context.actions.canPerform(.renameBranch(name: nil)))
            #expect(!fixture.context.actions.canPerform(.deleteBranch(name: nil)))
            try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
            await fixture.settle()
            #expect(try await availability(fixture) == allEnabled)

            // Interrupted between commits: nothing is conflicted, and it's
            // a rebase all the same.
            try await interruptRebase(of: "feature", onto: "other", in: fixture.local)
            await fixture.refresh()
            #expect(operations.current?.phase == .interrupted)
            #expect(try await availability(fixture) == allDisabled)
            try await operations.abortOperation()
            await fixture.settle()
            #expect(try await availability(fixture) == allEnabled)
        }
    }
}

// While a rebase waits on conflicts only untracked files, which the rebase
// leaves alone, can be discarded: from a file's context menu, from the
// multiple selection's Discard Changes…, and with Edit ▸ Delete alike.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Discarding during a rebase's conflicts", .offline, .hangGuard(minutes: 5)) @MainActor
struct RebaseConflictDiscardTests {
    /// Whether `items` offers Discard.
    private func offersDiscard(_ items: [FileMenuItem]) -> Bool {
        items.contains { $0.kind == .command(.discard) }
    }

    @Test("only untracked files can be discarded, however the discard is asked for")
    func onlyUntracked() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let controller = ChangesController(context: fixture.context, repository: fixture.repository)
            let readme = try fixture.file("README.md")
            let loader = try fixture.file("Sources/App/Loader.swift")
            #expect(readme.status.kind != .untracked)
            #expect(loader.status.kind == .untracked)
            #expect(controller.canDiscard([readme, loader]))

            fixture.repository.operations.conflictState = .rebase(
                currentTip: String(repeating: "b", count: 40),
                targetBranch: "topic",
                baseBranch: "main",
                originalBranchTip: String(repeating: "c", count: 40),
                baseBranchTip: String(repeating: "d", count: 40),
                manualResolutions: [:]
            )

            // The context menu: Discard for an untracked file only.
            #expect(offersDiscard(controller.menuItems(for: [loader.id])))
            #expect(!offersDiscard(controller.menuItems(for: [readme.id])))

            // A selection, for the multiple selection's Discard Changes… and
            // Edit ▸ Delete: only when every file in it is untracked.
            changes.select(fileIDs: [readme.id, loader.id])
            #expect(!controller.canDiscard(controller.selectedFiles))
            changes.select(fileIDs: [readme.id])
            #expect(!controller.canDiscard(controller.selectedFiles))
            changes.select(fileIDs: [loader.id])
            #expect(controller.canDiscard(controller.selectedFiles))
            #expect(!controller.canDiscard([]))
        }
    }
}

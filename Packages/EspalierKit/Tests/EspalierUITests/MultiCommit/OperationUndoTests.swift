// A squash's Undo through the window's undo manager: Edit ▸ Undo offers it
// after the toast closes while the state layer's undo is valid and the
// window shows the repository, runs it once, and drops it for good once the
// branch moves on or the window shows another repository.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Undo after the toast", .offline, .hangGuard(minutes: 5)) @MainActor
struct OperationUndoTests {
    /// `main` with A, B, and C, B and C squashed through the window, whose
    /// toast has closed. Returns the fixture, the window's undo manager, and
    /// `main`'s tip before the squash.
    private func squashed() async throws -> (OperationsFixture, UndoManager, String) {
        let fixture = try await makeOperationsFixture { local in
            for name in ["A", "B", "C"] {
                try await commitFile(local, "\(name).txt", "\(name)\n", message: name)
            }
        }
        await fixture.loadHistory()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        fixture.presenter.undoManager = undoManager
        let original = try await fixture.sha("main")
        let plan = try #require(SquashPlan.make(shas: [try await fixture.sha("main~1"), original], into: nil, in: fixture.repository))

        // The squash and its toast, as one event.
        undoManager.beginUndoGrouping()
        await MultiCommitActions.squash(plan, message: CommitContext(summary: "B and C", description: nil), in: fixture.context)
        undoManager.endUndoGrouping()
        await fixture.settle()
        #expect(try await fixture.summaries("main").prefix(2) == ["B and C", "A"])
        let toast = try #require(fixture.presenter.toasts.last)
        #expect(toast.undo != nil)
        fixture.presenter.dismissToast(toast.id)
        return (fixture, undoManager, original)
    }

    @Test("Edit ▸ Undo undoes the squash after its toast closed, once")
    func undoesAfterToast() async throws {
        let (fixture, undoManager, original) = try await squashed()
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(!undoManager.canUndo)
        await waitUntil { fixture.repository.operations.undo == nil }
        await fixture.settle()
        #expect(fixture.presenter.error == nil)
        #expect(try await fixture.sha("main") == original)
        #expect(fixture.presenter.undoRegistrations.isEmpty)
    }

    @Test("a new commit takes the squash's Undo off Edit ▸ Undo")
    func dropsOnceInvalid() async throws {
        let (fixture, undoManager, _) = try await squashed()
        #expect(undoManager.canUndo)

        let later = try await commitFile(fixture.local, "D.txt", "D\n", message: "D")
        await fixture.refresh()
        await waitUntil { fixture.presenter.undoRegistrations.isEmpty }
        #expect(!undoManager.canUndo)
        #expect(try await fixture.sha("main") == later)
    }

    @Test("showing another repository takes the squash's Undo off Edit ▸ Undo for good")
    func dropsOnLeavingRepository() async throws {
        let (fixture, undoManager, _) = try await squashed()
        let squashedTip = try await fixture.sha("main")
        #expect(undoManager.canUndo)

        let (other, _) = try await setupRepositoryWithRemote()
        _ = try await fixture.harness.addAndSelect(other, to: fixture.app)
        await waitUntil { fixture.presenter.undoRegistrations.isEmpty }
        #expect(!undoManager.canUndo)

        // Back in the repository, where the state layer's undo is still
        // valid: it isn't offered again.
        fixture.app.select(.repository(fixture.repository.id))
        await fixture.settle()
        #expect(fixture.context.repository === fixture.repository)
        #expect(fixture.repository.operations.undo != nil)
        #expect(fixture.presenter.undoRegistrations.isEmpty)
        #expect(!undoManager.canUndo)
        #expect(try await fixture.sha("main") == squashedTip)
    }
}

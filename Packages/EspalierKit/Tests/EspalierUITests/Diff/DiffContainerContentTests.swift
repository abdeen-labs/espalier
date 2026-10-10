// What the diff container shows below its header for each state of the
// diff, which message a text diff with no hunks shows for each status, and
// how a submodule's commit changed. The snapshots draw one of each.

import EspalierCore
import GitKit
import Testing
@testable import EspalierUI

@Suite("Diff container content") @MainActor
struct DiffContainerContentTests {
    @Test("nothing selected shows a note; a file's first diff loading shows nothing; the previous diff stays while the next loads")
    func loadingStates() {
        // No file: "Select a file to see its changes".
        guard case .selectFile = DiffContainer.shown(.idle, hasFile: false) else {
            Issue.record("Expected the note")
            return
        }
        // A file without a diff yet.
        guard case .nothing = DiffContainer.shown(.idle, hasFile: true) else {
            Issue.record("Expected nothing")
            return
        }
        // Loading with nothing before it: the spinner shows after a delay.
        guard case .nothing = DiffContainer.shown(.loading(previous: nil), hasFile: true) else {
            Issue.record("Expected nothing")
            return
        }
        // Loading after another file: its diff stays, not interactive.
        let previous = Diff.text(DiffFixtures.swiftChange)
        guard case .diff(let shown, let isInteractive) = DiffContainer.shown(.loading(previous: previous), hasFile: true) else {
            Issue.record("Expected the previous diff")
            return
        }
        #expect(shown == previous)
        #expect(!isInteractive)
        // A failed load shows the error.
        let error = OperationError(.other("Could not read the file."), operation: .loadDiff)
        guard case .failed(let failure) = DiffContainer.shown(.failed(error), hasFile: true) else {
            Issue.record("Expected the error")
            return
        }
        #expect(failure.message == error.message)
    }

    @Test("a binary, unrenderable, or submodule diff shows its own view, interactive once loaded")
    func loadedKinds() {
        let removed = SubmoduleDiff(
            fullPath: "/Users/joe/Developer/espalier/Vendor/lib", path: "Vendor/lib", url: nil,
            status: SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false),
            oldSHA: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", newSHA: nil
        )
        for diff in [Diff.binary, .unrenderable, .submodule(removed)] {
            guard case .diff(let shown, let isInteractive) = DiffContainer.shown(.loaded(diff), hasFile: true) else {
                Issue.record("Expected \(diff)'s own view")
                continue
            }
            #expect(shown == diff)
            #expect(isInteractive)
        }
    }

    @Test("a submodule's commit was changed, added, or removed")
    func submoduleCommitChange() {
        func content(old: String?, new: String?) -> SubmoduleDiffContent {
            SubmoduleDiffContent(
                diff: SubmoduleDiff(
                    fullPath: "/Users/joe/Developer/espalier/Vendor/lib", path: "Vendor/lib", url: nil,
                    status: SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false),
                    oldSHA: old, newSHA: new
                ),
                readOnly: true
            )
        }
        let old = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
        let new = "0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"
        #expect(content(old: old, new: new).commitChange == .changed(from: old, to: new))
        #expect(content(old: nil, new: new).commitChange == .added(at: new))
        #expect(content(old: old, new: nil).commitChange == .removed(at: old))
        // Only its own files changed.
        #expect(content(old: nil, new: nil).commitChange == nil)
    }

    @Test("a text diff with no hunks says why, by the file's status")
    func noHunksMessages() {
        // A new or untracked file: "The file is empty".
        #expect(NoHunksView.message(status: .new(), hidesWhitespace: false) == .emptyFile)
        #expect(NoHunksView.message(status: .untracked(), hidesWhitespace: true) == .emptyFile)
        // A rename, with or without changes.
        #expect(NoHunksView.message(status: .renamed(oldPath: "a", renameIncludesModifications: false), hidesWhitespace: false) == .renamed)
        #expect(NoHunksView.message(status: .renamed(oldPath: "a", renameIncludesModifications: true), hidesWhitespace: true) == .renamedWithChanges)
        // A conflict the command line must resolve; a conflict with markers
        // isn't one.
        let manual = AppFileStatus.conflicted(.manualConflict(entry: ManualConflictEntry(action: .bothDeleted)))
        #expect(NoHunksView.message(status: manual, hidesWhitespace: false) == .manualConflict)
        let markers = AppFileStatus.conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 0))
        #expect(NoHunksView.message(status: markers, hidesWhitespace: false) == .noContentChanges)
        // Otherwise, whether whitespace changes are hidden.
        #expect(NoHunksView.message(status: .modified(), hidesWhitespace: true) == .onlyWhitespace)
        #expect(NoHunksView.message(status: .modified(), hidesWhitespace: false) == .noContentChanges)
        // Without a status (a diff built without a file change).
        #expect(NoHunksView.message(status: nil, hidesWhitespace: false) == .noContentChanges)
    }
}

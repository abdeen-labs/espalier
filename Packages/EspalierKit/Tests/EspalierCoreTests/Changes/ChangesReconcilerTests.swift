// Reconciling changed files against synthetic status results, including
// inclusion carried over a status-kind change.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing

private func status(_ files: [WorkingDirectoryFileChange]) -> StatusResult {
    StatusResult(
        currentBranch: "main",
        currentTip: String(repeating: "a", count: 40),
        exists: true,
        mergeHeadFound: false,
        squashMsgFound: false,
        rebaseInternalState: nil,
        isCherryPickingHeadFound: false,
        workingDirectory: .fromFiles(files),
        doConflictedFilesExist: false
    )
}

/// A partially included file (some lines excluded).
private func partial(_ path: String, status: AppFileStatus = .modified()) -> WorkingDirectoryFileChange {
    let selection = DiffSelection.fromInitialSelection(.all)
        .withSelectableLines([1, 2, 3])
        .withLineSelection(2, selected: false)
    return WorkingDirectoryFileChange(path: path, status: status, selection: selection)
}

@Suite("Changes reconciliation")
struct ChangesReconcilerTests {
    @Test("a whole-file choice survives a status-kind change; a partial one resets")
    func kindChange() {
        let result = updateChangedFiles(
            workingDirectory: .fromFiles([
                ModelFixtures.file("excluded.txt", status: .untracked(), included: false),
                partial("partial.txt", status: .untracked()),
            ]),
            selection: .workingDirectory(fileIDs: []),
            status: status([
                ModelFixtures.file("excluded.txt", status: .new()),
                ModelFixtures.file("partial.txt", status: .new()),
            ]),
            clearPartialState: false
        )
        #expect(result.workingDirectory.files.map { $0.selection.getSelectionType() } == [.none, .all])
    }

    @Test("keeps the selected files that remain, else selects the first")
    func selection() {
        let a = ModelFixtures.file("a.txt")
        let b = ModelFixtures.file("b.txt")
        let current = WorkingDirectoryStatus.fromFiles([a, b])

        let kept = updateChangedFiles(
            workingDirectory: current,
            selection: .workingDirectory(fileIDs: [b.id]),
            status: status([a, b]),
            clearPartialState: false
        )
        #expect(kept.selection == .workingDirectory(fileIDs: [b.id]))
        #expect(kept.keepsDiff)

        let committed = updateChangedFiles(
            workingDirectory: current,
            selection: .workingDirectory(fileIDs: [b.id]),
            status: status([a]),
            clearPartialState: false
        )
        #expect(committed.selection == .workingDirectory(fileIDs: [a.id]))
        #expect(!committed.keepsDiff)

        let empty = updateChangedFiles(
            workingDirectory: current,
            selection: .workingDirectory(fileIDs: [a.id]),
            status: status([]),
            clearPartialState: false
        )
        #expect(empty.selection == .workingDirectory(fileIDs: []))
        #expect(empty.workingDirectory.includeAll == true)

        let stash = updateChangedFiles(
            workingDirectory: current,
            selection: .stash(fileID: "x"),
            status: status([a]),
            clearPartialState: false
        )
        #expect(stash.selection == .stash(fileID: "x"))
    }

    @Test("showing the working directory keeps its selection or selects the first file")
    func selectWorkingDirectory() {
        let a = ModelFixtures.file("a.txt")
        let files = WorkingDirectoryStatus.fromFiles([a])
        #expect(selectWorkingDirectoryFiles(files, selection: .workingDirectory(fileIDs: [])) == .workingDirectory(fileIDs: []))
        #expect(selectWorkingDirectoryFiles(files, selection: .stash(fileID: nil)) == .workingDirectory(fileIDs: [a.id]))
        #expect(selectWorkingDirectoryFiles(.fromFiles([]), selection: .stash(fileID: nil)) == .workingDirectory(fileIDs: []))
    }

    @Test("including and excluding files through the model")
    @MainActor
    func inclusion() {
        let model = ChangesModel()
        model.reconcile(status([ModelFixtures.file("a.txt"), ModelFixtures.file("b.txt")]), options: [])
        #expect(model.workingDirectory.includeAll == true)
        model.setIncludeAll(false)
        #expect(model.workingDirectory.includeAll == false)
        let b = model.workingDirectory.files[1]
        model.setIncluded([b.id], true)
        #expect(model.workingDirectory.files.map { $0.isIncludedInCommit() } == [false, true])
        #expect(model.workingDirectory.includeAll == nil)
        model.setLineSelection(partial("a.txt").selection, forFile: model.workingDirectory.files[0].id)
        #expect(model.workingDirectory.files[0].selection.getSelectionType() == .partial)
    }
}

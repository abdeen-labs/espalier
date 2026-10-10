// Ported from desktop/app/test/unit/stores/updates/update-changed-files-test.ts
// Additions at the end: partial selections carried over by ID, and the file
// and its selection kept when only its status kind changes.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing

private let allSelected = DiffSelection.fromInitialSelection(.all)
private let noneSelected = DiffSelection.fromInitialSelection(.none)

private let files = [
    WorkingDirectoryFileChange(path: "README.md", status: .modified(), selection: allSelected),
    WorkingDirectoryFileChange(path: "app/package.json", status: .modified(), selection: noneSelected),
]

/// A status result on `main` with `workingDirectory`'s files.
private func createStatus(workingDirectory: WorkingDirectoryStatus = .fromFiles([])) -> StatusResult {
    StatusResult(
        currentBranch: "main",
        currentTip: String(repeating: "a", count: 40),
        exists: true,
        mergeHeadFound: false,
        squashMsgFound: false,
        rebaseInternalState: nil,
        isCherryPickingHeadFound: false,
        workingDirectory: workingDirectory,
        doConflictedFilesExist: false
    )
}

/// A partially selected new file: lines 1-3 of 1-6 included.
private func makePartiallySelectedFile() -> WorkingDirectoryFileChange {
    let partialFileSelection = noneSelected
        .withSelectableLines([1, 2, 3, 4, 5, 6])
        .withLineSelection(1, selected: true)
        .withLineSelection(2, selected: true)
        .withLineSelection(3, selected: true)
    return WorkingDirectoryFileChange(path: "app/index.ts", status: .new(), selection: partialFileSelection)
}

@Suite("updateChangedFiles")
struct UpdateChangedFilesTests {
    // MARK: workingDirectory

    @Test("clears partial selection on file when clearPartialState is true")
    func clearsPartialSelection() throws {
        let partiallySelectedFile = makePartiallySelectedFile()
        let oldWorkingDirectory = WorkingDirectoryStatus.fromFiles(files + [partiallySelectedFile])

        let result = updateChangedFiles(
            workingDirectory: oldWorkingDirectory,
            selection: .workingDirectory(fileIDs: []),
            status: createStatus(workingDirectory: oldWorkingDirectory),
            clearPartialState: true
        )

        let partialFile = try #require(result.workingDirectory.findFileWithID(partiallySelectedFile.id))
        #expect(partialFile.selection.getSelectionType() == .none)
        // Whole-file choices are kept.
        #expect(result.workingDirectory.files.map(\.path) == ["app/index.ts", "app/package.json", "README.md"])
        #expect(result.workingDirectory.files.map { $0.selection.getSelectionType() } == [.none, .none, .all])
    }

    @Test("preserves partial selection on file when clearPartialState is false")
    func preservesPartialSelection() throws {
        let partiallySelectedFile = makePartiallySelectedFile()
        let oldWorkingDirectory = WorkingDirectoryStatus.fromFiles(files + [partiallySelectedFile])

        let result = updateChangedFiles(
            workingDirectory: oldWorkingDirectory,
            selection: .workingDirectory(fileIDs: []),
            status: createStatus(workingDirectory: oldWorkingDirectory),
            clearPartialState: false
        )

        let partialFile = try #require(result.workingDirectory.findFileWithID(partiallySelectedFile.id))
        #expect(partialFile.selection.getSelectionType() == .partial)
    }

    // MARK: selectedFileIDs

    @Test("selects the first file if none found in state")
    func selectsFirstFile() {
        let result = updateChangedFiles(
            workingDirectory: .fromFiles([]),
            selection: .workingDirectory(fileIDs: []),
            status: createStatus(workingDirectory: .fromFiles(files)),
            clearPartialState: false
        )

        // NOTE: `updateChangedFiles` sorts the paths and `app/package.json` will
        // appear in list before `README.md`
        #expect(result.selection == .workingDirectory(fileIDs: [files[1].id]))
    }

    @Test("remembers previous selection if file is found in status")
    func remembersSelection() {
        let firstFile = files[0].id
        let result = updateChangedFiles(
            workingDirectory: .fromFiles([]),
            selection: .workingDirectory(fileIDs: [firstFile]),
            status: createStatus(workingDirectory: .fromFiles(files)),
            clearPartialState: false
        )
        #expect(result.selection == .workingDirectory(fileIDs: [firstFile]))
    }

    @Test("clears selection if no files found in status")
    func clearsSelection() {
        let firstFile = files[0].id
        let result = updateChangedFiles(
            workingDirectory: .fromFiles([]),
            selection: .workingDirectory(fileIDs: [firstFile]),
            status: createStatus(),
            clearPartialState: false
        )
        #expect(result.selection == .workingDirectory(fileIDs: []))
    }

    // MARK: diff

    @Test("clears diff if selected file is not in previous state")
    func clearsDiff() {
        let workingDirectory = WorkingDirectoryStatus.fromFiles(files)
        let result = updateChangedFiles(
            workingDirectory: workingDirectory,
            // an unknown file was set as selected last time
            selection: .workingDirectory(fileIDs: ["id-from-file-not-in-status"]),
            status: createStatus(workingDirectory: workingDirectory),
            clearPartialState: false
        )
        #expect(!result.keepsDiff)
    }

    @Test("returns same diff if selected file from previous state is found")
    func keepsDiff() {
        let workingDirectory = WorkingDirectoryStatus.fromFiles(files)
        // first file was selected the last time we updated state
        let result = updateChangedFiles(
            workingDirectory: workingDirectory,
            selection: .workingDirectory(fileIDs: [files[0].id]),
            // same working directory is provided as last time
            status: createStatus(workingDirectory: workingDirectory),
            clearPartialState: false
        )
        #expect(result.keepsDiff)
        #expect(result.selection == .workingDirectory(fileIDs: [files[0].id]))
    }

    // MARK: Espalier

    @Test("a partial selection carries over by ID, exactly")
    func partialCarriesOver() throws {
        let partial = makePartiallySelectedFile()
        let result = updateChangedFiles(
            workingDirectory: .fromFiles(files + [partial]),
            selection: .workingDirectory(fileIDs: [partial.id]),
            // The status reports the file with a fresh, fully selected selection.
            status: createStatus(workingDirectory: .fromFiles(files + [partial.withIncludeAll(true)])),
            clearPartialState: false
        )
        let carried = try #require(result.workingDirectory.findFileWithID(partial.id))
        #expect(carried.selection == partial.selection)
        #expect((1...6).map { carried.selection.isSelected($0) } == [true, true, true, false, false, false])
        #expect(result.keepsDiff)
    }

    @Test("a selected file whose status kind changes stays selected, keeping a whole-file choice")
    func kindChangeKeepsSelection() throws {
        let untracked = WorkingDirectoryFileChange(path: "notes.txt", status: .untracked(), selection: noneSelected)
        let result = updateChangedFiles(
            workingDirectory: .fromFiles(files + [untracked]),
            selection: .workingDirectory(fileIDs: [untracked.id]),
            status: createStatus(workingDirectory: .fromFiles(files + [
                WorkingDirectoryFileChange(path: "notes.txt", status: .new(), selection: allSelected),
            ])),
            clearPartialState: false
        )
        let added = try #require(result.workingDirectory.files.first { $0.path == "notes.txt" })
        #expect(added.status.kind == .new)
        #expect(added.selection.getSelectionType() == .none)
        #expect(result.selection == .workingDirectory(fileIDs: [added.id]))
        // A different ID: the diff reloads.
        #expect(!result.keepsDiff)
    }

    @Test("files whose paths differ only in normalization stay apart")
    func exactPaths() {
        let composed = WorkingDirectoryFileChange(path: "caf\u{E9}.txt", status: .untracked(), selection: noneSelected)
        let decomposed = WorkingDirectoryFileChange(path: "cafe\u{301}.txt", status: .untracked(), selection: allSelected)
        let result = updateChangedFiles(
            workingDirectory: .fromFiles([composed, decomposed]),
            selection: .workingDirectory(fileIDs: [decomposed.id]),
            status: createStatus(workingDirectory: .fromFiles([composed.withIncludeAll(true), decomposed])),
            clearPartialState: false
        )
        #expect(result.workingDirectory.files.count == 2)
        let selections = result.workingDirectory.files.map { ($0.path.unicodeScalars.count, $0.selection.getSelectionType()) }
        #expect(selections.contains { $0 == (8, DiffSelectionType.none) })
        #expect(selections.contains { $0 == (9, .all) })
        #expect(result.selection == .workingDirectory(fileIDs: [decomposed.id]))
    }
}

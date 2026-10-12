// Ported from desktop/app/test/unit/filter-changes-logic-test.ts
// Plus tests of the text matching (fuzzaldrin-plus's rule) and of the
// model's filtered list. "should bypass filter logic when the changes
// filter is hidden" has no counterpart: the changes filter is always shown.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing

// Helper function to create a test file
private func createTestFile(_ path: String, _ status: AppFileStatus, _ selectionType: DiffSelectionType) -> WorkingDirectoryFileChange {
    let selection = selectionType == .partial
        ? DiffSelection.fromInitialSelection(.all).withLineSelection(0, selected: false)
        : DiffSelection.fromInitialSelection(selectionType)
    return WorkingDirectoryFileChange(path: path, status: status, selection: selection)
}

@Suite("filter-changes-logic")
struct FilterChangesLogicTests {
    // MARK: applyFilterOptions, when no filters are active

    @Test("should show all files")
    func showsAllFiles() {
        let filters = FileListFilter()

        let newFile = createTestFile("new.txt", .new(), .all)
        let modifiedFile = createTestFile("modified.txt", .modified(), .all)
        let deletedFile = createTestFile("deleted.txt", .deleted(), .all)

        #expect(filters.matchesOptions(newFile))
        #expect(filters.matchesOptions(modifiedFile))
        #expect(filters.matchesOptions(deletedFile))
    }

    // MARK: applyFilterOptions, when using AND logic

    @Test("should show files matching ALL active filters")
    func andLogic() {
        let filters = FileListFilter(includedInCommit: true, newFiles: true)

        // Staged new file - matches both filters
        let stagedNewFile = createTestFile("staged-new.txt", .new(), .all)
        // Unstaged new file - doesn't match included filter
        let unstagedNewFile = createTestFile("unstaged-new.txt", .new(), .none)
        // Staged modified file - doesn't match new file filter
        let stagedModifiedFile = createTestFile("staged-modified.txt", .modified(), .all)

        #expect(filters.matchesOptions(stagedNewFile))
        #expect(!filters.matchesOptions(unstagedNewFile))
        #expect(!filters.matchesOptions(stagedModifiedFile))
    }

    @Test("should handle conflicting filters correctly")
    func conflictingFilters() {
        let filters = FileListFilter(includedInCommit: true, excludedFromCommit: true)

        let stagedFile = createTestFile("staged.txt", .modified(), .all)
        let unstagedFile = createTestFile("unstaged.txt", .modified(), .none)

        // No file can be both staged and unstaged
        #expect(!filters.matchesOptions(stagedFile))
        #expect(!filters.matchesOptions(unstagedFile))
    }

    @Test("should treat untracked files as new files")
    func untrackedAsNew() {
        let filters = FileListFilter(newFiles: true)
        let untrackedFile = createTestFile("untracked.txt", .untracked(), .none)
        #expect(filters.matchesOptions(untrackedFile))
    }

    @Test("should match excluded files when excluded filter is active")
    func excludedFilter() {
        let filters = FileListFilter(excludedFromCommit: true)

        let excludedFile = createTestFile("excluded.txt", .modified(), .none)
        let includedFile = createTestFile("included.txt", .modified(), .all)

        #expect(filters.matchesOptions(excludedFile))
        #expect(!filters.matchesOptions(includedFile))
    }

    // MARK: isCommittingFileHiddenByFilter

    @Test("should return false when no filters are active")
    func hiddenNoFilters() {
        #expect(!isCommittingFileHiddenByFilter(
            ["file1", "file2"],
            visibleFileIDs: ["file1", "file2"].exactSet,
            fileCount: 2,
            FileListFilter()
        ))
    }

    @Test("should return true when committing files not in filtered list")
    func hiddenFiles() {
        #expect(isCommittingFileHiddenByFilter(
            ["file1", "file2", "file3"],
            visibleFileIDs: ["file1", "file2"].exactSet,
            fileCount: 5,
            FileListFilter(includedInCommit: true)
        ))
    }

    @Test("should return false when all files remain visible after filtering")
    func allVisible() {
        #expect(!isCommittingFileHiddenByFilter(
            ["file1", "file2"],
            visibleFileIDs: ["file1", "file2"].exactSet,
            fileCount: 2,
            FileListFilter(text: "src", modifiedFiles: true)
        ))
    }

    // MARK: getNoResultsMessage

    @Test("should return undefined when no filters active")
    func noMessage() {
        #expect(FileListFilter().noResultsMessage == nil)
    }

    @Test("should return message with text filter")
    func textMessage() {
        #expect(FileListFilter(text: "test").noResultsMessage != nil)
    }

    @Test("should return message with multiple filters")
    func multipleMessage() {
        #expect(FileListFilter(includedInCommit: true, newFiles: true).noResultsMessage != nil)
    }

    // MARK: hasActiveFilters

    @Test("should return false when no text or filter options are active")
    func noActiveFilters() {
        #expect(!FileListFilter().hasActiveFilters)
    }

    @Test("should return true when either text or filter options are active")
    func activeFilters() {
        #expect(FileListFilter(text: "src").hasActiveFilters)
        #expect(FileListFilter(modifiedFiles: true).hasActiveFilters)
    }

    // MARK: Espalier: text matching

    @Test("text matches the path's characters in order, ignoring case")
    func fuzzyText() {
        let file = createTestFile("app/src/ui/changes/filter-changes-list.tsx", .modified(), .all)
        for query in ["filter", "FCL", "fcl", "app/src", "changes list", "tsx", "a s u c f"] {
            #expect(FileListFilter(text: query).matchesText(file), "\(query)")
        }
        for query in ["xst", "zebra", "tsxx", "qq"] {
            #expect(!FileListFilter(text: query).matchesText(file), "\(query)")
        }
        // Capitals in the path, and beyond ASCII.
        #expect(FileListFilter(text: "readme").matchesText(createTestFile("Docs/README.md", .modified(), .all)))
        #expect(FileListFilter(text: "ÜN").matchesText(createTestFile("Ünïcode.txt", .modified(), .all)))
        #expect(!FileListFilter(text: "üz").matchesText(createTestFile("Ünïcode.txt", .modified(), .all)))
    }

    @Test("separators in the text are optional, but one alone must appear")
    func optionalCharacters() {
        let file = createTestFile("src/main.swift", .modified(), .all)
        // `-`, `_`, `:`, spaces, and slashes needn't appear in the path.
        #expect(FileListFilter(text: "src-main").matchesText(file))
        #expect(FileListFilter(text: "src_main").matchesText(file))
        #expect(FileListFilter(text: "s:m").matchesText(file))
        // A text of only optional characters matches when one of them does.
        #expect(FileListFilter(text: "/").matchesText(file))
        #expect(!FileListFilter(text: "-").matchesText(file))
        // A text longer than the path can't match.
        #expect(!FileListFilter(text: "src/main.swift.orig").matchesText(file))
        #expect(FileListFilter(text: "").matchesText(file))
    }

    @Test("the filtered list keeps the files' order and applies text and options together")
    @MainActor
    func modelVisibleFiles() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let record = ModelFixtures.record()
        let repository = RepositoryModel(record: record, app: app, environment: harness.environment)
        repository.changes.reconcile(status([
            createTestFile("README.md", .modified(), .all),
            createTestFile("src/app.swift", .new(), .all),
            createTestFile("src/old.swift", .deleted(), .none),
        ]), options: [])

        let changes = repository.changes
        #expect(changes.visibleFiles.map(\.path) == ["README.md", "src/app.swift", "src/old.swift"])

        changes.filter = FileListFilter(text: "src")
        #expect(changes.visibleFiles.map(\.path) == ["src/app.swift", "src/old.swift"])
        #expect(changes.includedFilesHiddenByFilter.map(\.path) == ["README.md"])

        changes.filter.deletedFiles = true
        #expect(changes.visibleFiles.map(\.path) == ["src/old.swift"])
        #expect(changes.includedFilesHiddenByFilter.map(\.path) == ["README.md", "src/app.swift"])
        #expect(changes.visibleIncludeAll == false)

        // The header checkbox includes only what's shown.
        changes.setVisibleFilesIncluded(true)
        #expect(changes.workingDirectory.files.map { $0.selection.getSelectionType() } == [.all, .all, .all])

        changes.filter = FileListFilter(text: "zzz")
        #expect(changes.visibleFiles.isEmpty)
        #expect(changes.noResultsMessage != nil)

        // Cleared, everything shows and nothing is hidden.
        changes.filter = FileListFilter()
        #expect(changes.visibleFiles.count == 3)
        #expect(changes.includedFilesHiddenByFilter.isEmpty)
        #expect(changes.noResultsMessage == nil)
    }

    @Test("checkboxes show submodules and rebase conflicts as desktop does")
    @MainActor
    func inclusionStates() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = RepositoryModel(record: ModelFixtures.record(), app: app, environment: harness.environment)
        let changes = repository.changes

        let plain = createTestFile("a.txt", .modified(), .partial)
        #expect(changes.inclusionState(of: plain) == FileInclusionState(value: nil, isEnabled: true, help: nil))

        let uncommittable = createTestFile(
            "sub",
            .modified(submoduleStatus: SubmoduleStatus(commitChanged: false, modifiedChanges: true, untrackedChanges: false)),
            .all
        )
        let state = changes.inclusionState(of: uncommittable)
        #expect(state.value == false)
        #expect(!state.isEnabled)
        #expect(state.help != nil)

        let partlyCommittable = createTestFile(
            "sub",
            .modified(submoduleStatus: SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: true)),
            .all
        )
        let partly = changes.inclusionState(of: partlyCommittable)
        #expect(partly.value == nil)
        #expect(partly.isEnabled)
        #expect(partly.help != nil)

        // During a rebase's conflicts, tracked files show as included and
        // untracked ones, which the rebase skips, as not; none can change.
        changes.reconcile(status([
            createTestFile("a.txt", .modified(), .none),
            createTestFile("new.txt", .untracked(), .all),
        ]), options: [])
        repository.operations.conflictState = .rebase(
            currentTip: String(repeating: "b", count: 40),
            targetBranch: "topic",
            baseBranch: "main",
            originalBranchTip: String(repeating: "c", count: 40),
            baseBranchTip: String(repeating: "d", count: 40),
            manualResolutions: [:]
        )
        let tracked = try #require(changes.workingDirectory.files.first { $0.path == "a.txt" })
        let untracked = try #require(changes.workingDirectory.files.first { $0.path == "new.txt" })
        #expect(changes.inclusionState(of: tracked) == FileInclusionState(value: true, isEnabled: false, help: nil))
        #expect(changes.inclusionState(of: untracked) == FileInclusionState(value: false, isEnabled: false, help: nil))
        // The header checkbox follows the files shown.
        #expect(changes.visibleIncludeAll == nil)
        changes.filter = FileListFilter(text: "a.txt")
        #expect(changes.visibleIncludeAll == true)
        changes.filter = FileListFilter(text: "new")
        #expect(changes.visibleIncludeAll == false)
    }

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
}

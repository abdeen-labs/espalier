import GitKit
import Testing
import TestSupport

@Suite("Status model behavior")
struct StatusBehaviorTests {
    private let all = DiffSelection.fromInitialSelection(.all)
    private let none = DiffSelection.fromInitialSelection(.none)

    @Test("file change IDs include the old path of copies and renames")
    func fileChangeIDs() {
        #expect(WorkingDirectoryFileChange(path: "a", status: .modified(), selection: all).id == "Modified+a")
        #expect(
            WorkingDirectoryFileChange(
                path: "new",
                status: .renamed(oldPath: "old", renameIncludesModifications: false),
                selection: all
            ).id == "Renamed+new+old"
        )
        #expect(
            CommittedFileChange(
                path: "b",
                status: .copied(oldPath: "a", renameIncludesModifications: false),
                commitish: "c",
                parentCommitish: "p"
            ).id == "Copied+b+a"
        )
    }

    @Test("conflicted statuses keep their own submodule status")
    func conflictedStatus() {
        let submodule = SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false)
        let entry = UnmergedEntry(action: .bothModified, submoduleStatus: submodule)
        let withMarkers = AppFileStatus.conflicted(.conflictsWithMarkers(entry: entry, conflictMarkerCount: 3))
        let manual = ConflictedFileStatus.manualConflict(entry: UnmergedEntry(action: .deletedByThem))

        #expect(withMarkers.kind == .conflicted)
        #expect(withMarkers.submoduleStatus == nil)
        #expect(isConflictedFileStatus(withMarkers))
        #expect(!isConflictedFileStatus(.modified(submoduleStatus: submodule)))
        #expect(isConflictWithMarkers(.conflictsWithMarkers(entry: entry, conflictMarkerCount: 0)))
        #expect(!isConflictWithMarkers(manual))
        #expect(isManualConflict(manual))
        #expect(manual.entry.them == .deleted)
    }

    @Test("includeAll reflects the files' selections")
    func includeAll() {
        let partial = all.withLineSelection(1, selected: false)
        #expect(WorkingDirectoryStatus.fromFiles([]).includeAll == true)
        #expect(WorkingDirectoryStatus.fromFiles([file("a", all)]).includeAll == true)
        #expect(WorkingDirectoryStatus.fromFiles([file("a", none)]).includeAll == false)
        #expect(WorkingDirectoryStatus.fromFiles([file("a", all), file("b", none)]).includeAll == nil)
        #expect(WorkingDirectoryStatus.fromFiles([file("a", partial)]).includeAll == nil)
    }

    @Test("finds files by ID, the last one winning for a repeated ID")
    func findFiles() throws {
        let status = WorkingDirectoryStatus.fromFiles([file("a", all), file("b", all), file("a", none)])
        #expect(status.findFileIndexByID("Modified+a") == 2)
        #expect(try #require(status.findFileWithID("Modified+a")).isExcludedFromCommit())
        #expect(status.findFileIndexByID("missing") == nil)
        #expect(status.findFileWithID("missing") == nil)
    }

    @Test("keeps IDs apart that differ only in Unicode normalization")
    func findFilesByExactID() {
        let status = WorkingDirectoryStatus.fromFiles([file(Cafe.precomposed, all), file(Cafe.decomposed, none)])
        #expect(status.findFileIndexByID("Modified+\(Cafe.precomposed)") == 0)
        #expect(status.findFileIndexByID("Modified+\(Cafe.decomposed)") == 1)
        #expect(status.findFileWithID("Modified+\(Cafe.decomposed)")?.isExcludedFromCommit() == true)
    }

    @Test("includes or excludes every file")
    func withIncludeAllFiles() {
        let status = WorkingDirectoryStatus.fromFiles([file("a", all), file("b", none)])
        let excluded = status.withIncludeAllFiles(false)
        #expect(excluded.includeAll == false)
        #expect(excluded.files.allSatisfy { $0.isExcludedFromCommit() })
        let included = status.withIncludeAllFiles(true)
        #expect(included.includeAll == true)
        #expect(included.files.allSatisfy { $0.isIncludedInCommit() })
    }

    @Test("partially selected files are neither included nor excluded")
    func partialFile() {
        let change = file("a", all.withLineSelection(1, selected: false))
        #expect(!change.isIncludedInCommit())
        #expect(!change.isExcludedFromCommit())
        #expect(change.isModified())
        #expect(!change.isNew())
    }

    private func file(_ path: String, _ selection: DiffSelection) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(path: path, status: .modified(), selection: selection)
    }
}

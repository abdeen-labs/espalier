// Ported from desktop/app/test/unit/status-utils-test.ts

import GitKit
import Testing
import TestSupport

private let bothModified = AppFileStatus.conflicted(.conflictsWithMarkers(
    entry: UnmergedEntry(action: .bothModified),
    conflictMarkerCount: 1
))

private func makeFile(_ path: String, _ kind: AppFileStatusKind) -> WorkingDirectoryFileChange {
    let status: AppFileStatus =
        switch kind {
        case .conflicted: bothModified
        case .new: .new()
        case .modified: .modified()
        case .deleted: .deleted()
        case .untracked: .untracked()
        case .copied: .copied(oldPath: "", renameIncludesModifications: false)
        case .renamed: .renamed(oldPath: "", renameIncludesModifications: false)
        }

    return WorkingDirectoryFileChange(path: path, status: status, selection: .fromInitialSelection(.all))
}

@Suite("lib/status")
struct StatusUtilsTests {
    @Suite("mapStatus")
    struct MapStatus {
        @Test("returns \"Resolved\" for conflicted files without markers")
        func resolvedFiles() {
            #expect(mapStatus(bothModified) == "Conflicted")
            let resolved = AppFileStatus.conflicted(.conflictsWithMarkers(
                entry: UnmergedEntry(action: .bothModified),
                conflictMarkerCount: 0
            ))
            #expect(mapStatus(resolved) == "Resolved")
            #expect(mapStatus(.conflicted(.manualConflict(entry: UnmergedEntry(action: .deletedByUs)))) == "Conflicted")
        }
    }

    @Suite("hasConflictedFiles")
    struct HasConflictedFiles {
        @Test("finds conflicted files", arguments: [
            NamedCase("returns false for an empty working directory", (files: [WorkingDirectoryFileChange](), expected: false)),
            NamedCase("returns false when no files are conflicted", (
                files: [makeFile("a.txt", .modified), makeFile("b.txt", .new)],
                expected: false
            )),
            NamedCase("returns true when a file is conflicted", (
                files: [makeFile("a.txt", .modified), makeFile("b.txt", .conflicted)],
                expected: true
            )),
        ])
        func findsConflictedFiles(_ testCase: NamedCase<(files: [WorkingDirectoryFileChange], expected: Bool)>) {
            let wd = WorkingDirectoryStatus.fromFiles(testCase.value.files)
            #expect(hasConflictedFiles(wd) == testCase.value.expected)
        }
    }

    // The rest of the status helpers.
    @Suite("conflict helpers")
    struct ConflictHelpers {
        @Test("filters resolved, conflicted, unmerged, and untracked files")
        func filters() {
            let resolvedByMarkers = WorkingDirectoryFileChange(
                path: "resolved",
                status: .conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothAdded), conflictMarkerCount: 0)),
                selection: .fromInitialSelection(.all)
            )
            let binary = WorkingDirectoryFileChange(
                path: "binary",
                status: .conflicted(.manualConflict(entry: UnmergedEntry(action: .bothModified))),
                selection: .fromInitialSelection(.all)
            )
            let chosen = WorkingDirectoryFileChange(
                path: "chosen",
                status: .conflicted(.manualConflict(entry: UnmergedEntry(action: .deletedByThem))),
                selection: .fromInitialSelection(.all)
            )
            let markers = makeFile("markers", .conflicted)
            let untracked = makeFile("untracked", .untracked)
            let status = WorkingDirectoryStatus.fromFiles([resolvedByMarkers, binary, chosen, markers, untracked])
            let manualResolutions: [String: ManualConflictResolution] = ["chosen": .ours]

            #expect(getResolvedFiles(status, manualResolutions).map(\.path) == ["resolved", "chosen"])
            #expect(getConflictedFiles(status, manualResolutions).map(\.path) == ["binary", "markers"])
            #expect(getUnmergedFiles(status).map(\.path) == ["resolved", "binary", "chosen", "markers"])
            #expect(getUntrackedFiles(status).map(\.path) == ["untracked"])
        }
    }
}

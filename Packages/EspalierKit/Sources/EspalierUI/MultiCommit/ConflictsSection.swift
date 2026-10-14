// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/conflicts-dialog.tsx and ui/lib/conflicts/render-functions.tsx
//
// The conflicted files, their order, and the summary's copy. The Changes
// list shows each conflicted file's state and buttons in its row.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// The conflicted files, as the Changes list's rows show them.
nonisolated public struct ConflictsSectionContent: Sendable, Equatable {
    /// Every file that was conflicted, resolved or not, in the status's
    /// order.
    public var rows: [ConflictFileRowContent]

    public init(rows: [ConflictFileRowContent]) {
        self.rows = rows
    }

    /// The files that still need the user.
    public var unresolvedCount: Int {
        rows.filter(\.isUnresolved).count
    }

    /// The section for the working directory's files: an operation's
    /// conflicts, with its manual resolutions and branches, or a stash
    /// restore's (no sides to pick); counts in `numberFormat`.
    public static func make(
        files: [WorkingDirectoryFileChange],
        manualResolutions: [String: ManualConflictResolution],
        branches: ConflictBranches?,
        offersSides: Bool,
        numberFormat: NumberFormat
    ) -> ConflictsSectionContent {
        ConflictsSectionContent(rows: files.compactMap { file in
            ConflictFileRowContent.make(
                file,
                manualResolution: manualResolutions[file.path],
                branches: branches,
                offersSides: offersSides,
                numberFormat: numberFormat
            )
        })
    }

    /// The section for a repository, counts in `numberFormat`: nil when
    /// nothing is conflicted.
    @MainActor
    public static func make(_ repository: RepositoryModel, numberFormat: NumberFormat) -> ConflictsSectionContent? {
        let operations = repository.operations
        let files = repository.changes.workingDirectory.files
        if let conflictState = operations.conflictState {
            return make(
                files: files,
                manualResolutions: conflictState.manualResolutions,
                branches: operations.conflictBranches,
                offersSides: true,
                numberFormat: numberFormat
            )
        }
        // A stash restore that conflicted: its files, with nothing to pick.
        guard repository.stash.conflictedRestore != nil || files.contains(where: { $0.status.kind == .conflicted }) else {
            return nil
        }
        let content = make(files: files, manualResolutions: [:], branches: nil, offersSides: false, numberFormat: numberFormat)
        return content.rows.isEmpty ? nil : content
    }
}

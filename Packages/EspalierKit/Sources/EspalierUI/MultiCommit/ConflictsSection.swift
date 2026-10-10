// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/conflicts-dialog.tsx and ui/lib/conflicts/render-functions.tsx
//
// The conflicted files, their order, and the summary's copy, as a section
// of the Changes list, which the Changes column embeds above the changes.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the conflicts section shows.
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

    /// "Conflicts · 2 conflicted files", or "Conflicts · All resolved".
    public var header: String {
        let count = unresolvedCount
        if count == 0 {
            return "Conflicts · All resolved"
        }
        return "Conflicts · \(count) conflicted \(count == 1 ? "file" : "files")"
    }

    /// The section for the working directory's files: an operation's
    /// conflicts, with its manual resolutions and branches, or a stash
    /// restore's (no sides to pick).
    public static func make(
        files: [WorkingDirectoryFileChange],
        manualResolutions: [String: ManualConflictResolution],
        branches: ConflictBranches?,
        offersSides: Bool
    ) -> ConflictsSectionContent {
        ConflictsSectionContent(rows: files.compactMap { file in
            ConflictFileRowContent.make(
                file,
                manualResolution: manualResolutions[file.path],
                branches: branches,
                offersSides: offersSides
            )
        })
    }

    /// The section for a repository: nil when nothing is conflicted.
    @MainActor
    public static func make(_ repository: RepositoryModel) -> ConflictsSectionContent? {
        let operations = repository.operations
        let files = repository.changes.workingDirectory.files
        if let conflictState = operations.conflictState {
            return make(
                files: files,
                manualResolutions: conflictState.manualResolutions,
                branches: operations.conflictBranches,
                offersSides: true
            )
        }
        // A stash restore that conflicted: its files, with nothing to pick.
        guard repository.stash.conflictedRestore != nil || files.contains(where: { $0.status.kind == .conflicted }) else {
            return nil
        }
        let content = make(files: files, manualResolutions: [:], branches: nil, offersSides: false)
        return content.rows.isEmpty ? nil : content
    }
}

/// The conflicted files, as a section of the Changes list.
public struct ConflictsSection: View {
    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        if let content = ConflictsSectionContent.make(repository) {
            ConflictsSectionView(content: content, actions: { row in rowActions(for: row) })
        }
    }

    private func rowActions(for row: ConflictFileRowContent) -> ConflictFileRowActions {
        let integrations = context.app.integrations
        let path = POSIXPath.join(repository.record.path, row.path)
        let actions = context.actions
        let operations = repository.operations
        return ConflictFileRowActions(
            editorName: integrations.editorLabel,
            isEditorAvailable: integrations.isEditorAvailable,
            openInEditor: { actions.perform(.openInEditor(path: path)) },
            openWithDefaultProgram: { actions.perform(.openWithDefaultProgram(path: path)) },
            showInFinder: { actions.perform(.showInFinder(path: path)) },
            choose: { resolution in operations.setManualResolution(resolution, forPath: row.path) }
        )
    }
}

/// The section's look, value-driven.
struct ConflictsSectionView: View {
    let content: ConflictsSectionContent
    let actions: (ConflictFileRowContent) -> ConflictFileRowActions

    var body: some View {
        Section {
            ForEach(content.rows) { row in
                ConflictFileRow(content: row, actions: actions(row))
            }
        } header: {
            SectionLabel(content.header)
                .padding(.horizontal, Metrics.ConflictRow.horizontalPadding)
                .padding(.bottom, Metrics.grid)
        } footer: {
            if content.unresolvedCount > 0 {
                Text(OperationPanelContent.hint)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.ConflictRow.horizontalPadding)
                    .padding(.top, Metrics.insetSmall)
            }
        }
    }
}

// Ported in part from desktop/app/src/ui/lib/conflicts/unmerged-file.tsx
//
// A conflicted file's row in the Changes list's conflicts section: its
// status ("3 conflicts", "Manual conflict", "File does not exist on
// <branch>.", "No conflicts remaining", "Using the modified file from
// <branch>"), its actions (Open in <Editor>, disabled without an editor; the
// manual resolution menu; Undo), and their copy.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What a conflicted file's row shows.
nonisolated public struct ConflictFileRowContent: Sendable, Equatable, Identifiable {
    /// Where the file is.
    public enum State: Sendable, Equatable {
        /// Conflict markers left: the number of conflicts.
        case markers(conflicts: Int)
        /// A conflict without markers (binary, deleted on one side): the
        /// user picks a side.
        case manual
        /// Resolved, by removing the markers or by picking a side
        /// (`isUndoable`).
        case resolved(isUndoable: Bool)
    }

    public var path: String
    public var state: State
    /// The line under the name.
    public var status: String
    /// The manual resolution menu's items, ours then theirs (nil while
    /// resolved, and for a stash restore, which has no sides to pick).
    public var oursLabel: String?
    public var theirsLabel: String?

    public init(path: String, state: State, status: String, oursLabel: String? = nil, theirsLabel: String? = nil) {
        self.path = path
        self.state = state
        self.status = status
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
    }

    public var id: String {
        path
    }

    /// The file's name.
    public var fileName: String {
        POSIXPath.basename(path)
    }

    /// The folder it's in, or nil at the root.
    public var directory: String? {
        let directory = POSIXPath.dirname(path)
        return directory == "." ? nil : directory
    }

    /// Whether the file still needs the user.
    public var isUnresolved: Bool {
        switch state {
        case .markers, .manual: true
        case .resolved: false
        }
    }

    /// The row for a conflicted file; nil for a file that isn't conflicted.
    ///
    /// - Parameters:
    ///   - branches: The branches on each side, for the labels.
    ///   - offersSides: Whether a side can be picked (an operation is in
    ///     progress; a stash restore has none).
    public static func make(
        _ file: WorkingDirectoryFileChange,
        manualResolution: ManualConflictResolution?,
        branches: ConflictBranches?,
        offersSides: Bool = true
    ) -> ConflictFileRowContent? {
        guard case .conflicted(let status) = file.status else {
            return nil
        }
        let ours = branches?.ours
        let theirs = branches?.theirs
        let entry = status.entry
        let oursLabel = offersSides ? getLabelForManualResolutionOption(entry.us, ours) : nil
        let theirsLabel = offersSides ? getLabelForManualResolutionOption(entry.them, theirs) : nil

        if hasUnresolvedConflicts(status, manualResolution) {
            if case .conflictsWithMarkers(_, let markers, _) = status {
                // Each conflict has three markers (<<<<<<<, =======, >>>>>>>).
                let conflicts = (markers + 2) / 3
                return ConflictFileRowContent(
                    path: file.path,
                    state: .markers(conflicts: conflicts),
                    status: conflicts == 1 ? "1 conflict" : "\(conflicts) conflicts",
                    oursLabel: oursLabel,
                    theirsLabel: theirsLabel
                )
            }
            var description = "Manual conflict"
            if entry.us == .deleted || entry.them == .deleted {
                var targetBranch = "target branch"
                if entry.us == .deleted, let ours {
                    targetBranch = ours
                }
                if entry.them == .deleted, let theirs {
                    targetBranch = theirs
                }
                description = "File does not exist on \(targetBranch)."
            }
            return ConflictFileRowContent(
                path: file.path,
                state: .manual,
                status: description,
                oursLabel: oursLabel,
                theirsLabel: theirsLabel
            )
        }

        let noConflictMarkers: Bool = if case .conflictsWithMarkers(_, 0, _) = status { true } else { false }
        let resolvedMessage = "No conflicts remaining"
        let summary: String
        if noConflictMarkers {
            summary = resolvedMessage
        } else if manualResolution == .ours {
            summary = getUnmergedStatusEntryDescription(entry.us, ours)
        } else if manualResolution == .theirs {
            summary = getUnmergedStatusEntryDescription(entry.them, theirs)
        } else {
            summary = resolvedMessage
        }
        return ConflictFileRowContent(
            path: file.path,
            state: .resolved(isUndoable: summary != resolvedMessage),
            status: summary
        )
    }
}

/// What a conflict row's buttons do.
struct ConflictFileRowActions {
    /// The editor's name for "Open in <Editor>" (nil: "Open in External
    /// Editor").
    var editorName: String?
    /// Whether an editor is configured; Open in <Editor> is disabled
    /// without one.
    var isEditorAvailable: Bool
    var openInEditor: () -> Void = {}
    var openWithDefaultProgram: () -> Void = {}
    var showInFinder: () -> Void = {}
    var choose: (ManualConflictResolution?) -> Void = { _ in }
}

/// A conflicted file in the Changes list's conflicts section: its name,
/// folder and status, and what can be done with it.
struct ConflictFileRow: View {
    let content: ConflictFileRowContent
    let actions: ConflictFileRowActions

    var body: some View {
        // The name and the buttons on the first line; the folder and the
        // status under the name, across the whole row, so a long status
        // isn't cut short by the buttons.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Metrics.insetSmall) {
                glyph
                Text(content.fileName)
                    .font(Typography.row.weight(content.isUnresolved ? .medium : .regular))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: Metrics.grid)
                trailing
                    .fixedSize()
            }
            HStack(spacing: Metrics.insetSmall) {
                // The glyph's width, so the line starts under the name.
                glyph
                    .hidden()
                    .frame(height: 0)
                    .accessibilityHidden(true)
                secondaryLine
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.ConflictRow.horizontalPadding)
        .padding(.vertical, Metrics.ConflictRow.verticalPadding)
        .help(content.path)
        .contextMenu {
            menuItems
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.path), \(content.status)")
    }

    /// "Sources/App · 3 conflicts": the folder gives way to the status.
    private var secondaryLine: some View {
        HStack(spacing: 0) {
            if let directory = content.directory {
                Text(directory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: " · ")
                    .layoutPriority(1)
            }
            Text(content.status)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// The warning, or once resolved the check: one symbol that turns into
    /// the other (a symbol replace).
    private var glyph: some View {
        Image(systemName: content.isUnresolved ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(Color(espalier: content.isUnresolved ? Palette.warningMark : Palette.success))
            .contentTransition(.symbolEffect(.replace))
            .motion(Motion.arrive, value: content.isUnresolved)
            .accessibilityLabel(content.isUnresolved ? "Warning" : "Resolved")
    }

    @ViewBuilder
    private var trailing: some View {
        switch content.state {
        case .markers:
            HStack(spacing: 0) {
                // The column is narrow: the editor's name is the button's
                // label for VoiceOver and its tooltip, and the menus say it.
                Button(action: actions.openInEditor) {
                    Label(editorTitle, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.icon)
                .disabled(!actions.isEditorAvailable)
                .help(actions.isEditorAvailable ? editorTitle : "No editor configured in Settings ▸ Integrations")
                Menu {
                    menuItems
                } label: {
                    Label("File Resolution Options", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.icon)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("File Resolution Options")
            }
        case .manual:
            if content.oursLabel != nil {
                Menu {
                    sideItems
                } label: {
                    MenuCapsuleLabel("Resolve")
                }
                .menuStyle(.button)
                .buttonStyle(.quiet)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
            }
        case .resolved(let isUndoable):
            if isUndoable {
                Button("Undo") {
                    actions.choose(nil)
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
            }
        }
    }

    private var editorTitle: String {
        "Open in \(actions.editorName ?? "External Editor")"
    }

    /// The file's menu: open it, show it, pick a side.
    @ViewBuilder
    private var menuItems: some View {
        if case .markers = content.state {
            Button(editorTitle, action: actions.openInEditor)
                .disabled(!actions.isEditorAvailable)
        }
        Button("Open with Default App", action: actions.openWithDefaultProgram)
        Button("Show in Finder", action: actions.showInFinder)
        if content.isUnresolved, content.oursLabel != nil {
            Divider()
            sideItems
        } else if case .resolved(isUndoable: true) = content.state {
            Divider()
            Button("Undo") {
                actions.choose(nil)
            }
        }
    }

    @ViewBuilder
    private var sideItems: some View {
        if let oursLabel = content.oursLabel {
            Button(oursLabel) {
                actions.choose(.ours)
            }
        }
        if let theirsLabel = content.theirsLabel {
            Button(theirsLabel) {
                actions.choose(.theirs)
            }
        }
    }
}

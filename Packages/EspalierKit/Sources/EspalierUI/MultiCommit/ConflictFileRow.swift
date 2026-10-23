// Ported in part from desktop/app/src/ui/lib/conflicts/unmerged-file.tsx
//
// A conflicted file in the Changes list: its state ("3 conflicts", "Manual
// conflict", "File does not exist on <branch>.", "No conflicts remaining",
// "Using the modified file from <branch>"), its buttons at the end of its
// row (Open in <Editor>, disabled without an editor, and the file's menu;
// the manual resolution menu; Undo), and their copy. The sides are named by
// their branches ("Use main's Version"), "Current" and "Incoming" only for
// a side without one. Undo takes back the side chosen for the whole file,
// else the last side chosen for one of its conflicts (the diff's blocks).
// The row is the Changes table's (FileRow.swift); the band above the file's
// diff has the same state and buttons (ConflictBand.swift).

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
        /// (`isUndoable`: Undo can take that back).
        case resolved(isUndoable: Bool)
    }

    /// What Undo takes back.
    public enum Undo: Sendable, Equatable {
        /// The side chosen for the whole file, which changed nothing on
        /// disk.
        case side
        /// The last side chosen for one of its conflicts, which changed the
        /// file.
        case conflictSide
    }

    public var path: String
    public var state: State
    /// What's left, at the end of the row.
    public var status: String
    /// The manual resolution menu's items, ours then theirs (nil while
    /// resolved, and for a stash restore, which has no sides to pick).
    public var oursLabel: String?
    public var theirsLabel: String?
    /// The buttons for the same sides: "Use main's Version", "Use
    /// feature's Version" (nil when the menu has no items).
    public var oursVersionTitle: String?
    public var theirsVersionTitle: String?
    /// What Undo takes back, when it shows.
    public var undo: Undo?

    public init(
        path: String,
        state: State,
        status: String,
        oursLabel: String? = nil,
        theirsLabel: String? = nil,
        oursVersionTitle: String? = nil,
        theirsVersionTitle: String? = nil,
        undo: Undo? = nil
    ) {
        self.path = path
        self.state = state
        self.status = status
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
        self.oursVersionTitle = oursVersionTitle
        self.theirsVersionTitle = theirsVersionTitle
        self.undo = undo ?? (state == .resolved(isUndoable: true) ? .side : nil)
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
    ///   - canUndoConflictSide: Whether Undo can put back the last side
    ///     chosen for one of the file's conflicts
    ///     (`operations.canUndoConflictSide(forPath:)`).
    ///   - numberFormat: The format the conflicts' count is in.
    public static func make(
        _ file: WorkingDirectoryFileChange,
        manualResolution: ManualConflictResolution?,
        branches: ConflictBranches?,
        offersSides: Bool = true,
        canUndoConflictSide: Bool = false,
        numberFormat: NumberFormat
    ) -> ConflictFileRowContent? {
        guard case .conflicted(let status) = file.status else {
            return nil
        }
        let ours = branches?.ours
        let theirs = branches?.theirs
        let entry = status.entry
        let oursLabel = offersSides ? getLabelForManualResolutionOption(entry.us, ours) : nil
        let theirsLabel = offersSides ? getLabelForManualResolutionOption(entry.them, theirs) : nil
        let oursVersionTitle = offersSides ? versionTitle(ours, side: .ours) : nil
        let theirsVersionTitle = offersSides ? versionTitle(theirs, side: .theirs) : nil

        if hasUnresolvedConflicts(status, manualResolution) {
            if case .conflictsWithMarkers(_, _, let conflictCount, _) = status {
                // Markers left without a line that opens a conflict still
                // need resolving.
                let conflicts = max(conflictCount, 1)
                return ConflictFileRowContent(
                    path: file.path,
                    state: .markers(conflicts: conflicts),
                    status: conflicts == 1 ? "1 conflict" : "\(formatCount(conflicts, numberFormat)) conflicts",
                    oursLabel: oursLabel,
                    theirsLabel: theirsLabel,
                    oursVersionTitle: oursVersionTitle,
                    theirsVersionTitle: theirsVersionTitle,
                    undo: canUndoConflictSide ? .conflictSide : nil
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
                theirsLabel: theirsLabel,
                oursVersionTitle: oursVersionTitle,
                theirsVersionTitle: theirsVersionTitle
            )
        }

        let noConflictMarkers: Bool = if case .conflictsWithMarkers(_, 0, _, _) = status { true } else { false }
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
        let undo: Undo? = summary != resolvedMessage ? .side : (canUndoConflictSide ? .conflictSide : nil)
        return ConflictFileRowContent(
            path: file.path,
            state: .resolved(isUndoable: undo != nil),
            status: summary,
            undo: undo
        )
    }

    /// A side's name: its branch, else "Current" for ours and "Incoming"
    /// for theirs (a detached HEAD, a commit without a branch).
    static func sideName(_ branch: String?, side: ManualConflictResolution) -> String {
        if let branch, !branch.isEmpty {
            return branch
        }
        return side == .ours ? "Current" : "Incoming"
    }

    /// "Use main's Version" for a side named by its branch, "Use Current
    /// Version" or "Use Incoming Version" for one whose branch isn't known.
    static func versionTitle(_ branch: String?, side: ManualConflictResolution) -> String {
        guard let branch, !branch.isEmpty else {
            return "Use \(sideName(nil, side: side)) Version"
        }
        return "Use \(branch)'s Version"
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
    /// Picks a side for the whole file.
    var choose: (ManualConflictResolution) -> Void = { _ in }
    /// Undo: clears the side chosen for the whole file, or puts back the
    /// last side chosen for one conflict.
    var undo: () -> Void = {}
}

extension ConflictFileRowActions {
    /// What a conflicted file's buttons do in `repository`, in its row and
    /// in the band above its diff: open it, show it, pick a side, undo.
    @MainActor
    static func make(for row: ConflictFileRowContent, repository: RepositoryModel, context: WindowContext) -> ConflictFileRowActions {
        let integrations = context.app.integrations
        let path = POSIXPath.join(repository.record.path, row.path)
        let actions = context.actions
        let operations = repository.operations
        let undo = row.undo
        return ConflictFileRowActions(
            editorName: integrations.editorLabel,
            isEditorAvailable: integrations.isEditorAvailable,
            openInEditor: { actions.perform(.openInEditor(path: path)) },
            openWithDefaultProgram: { actions.perform(.openWithDefaultProgram(path: path)) },
            showInFinder: { actions.perform(.showInFinder(path: path)) },
            choose: { resolution in operations.setManualResolution(resolution, forPath: row.path) },
            undo: { [weak context] in
                switch undo {
                case .side?:
                    operations.setManualResolution(nil, forPath: row.path)
                case .conflictSide?:
                    Task {
                        await context?.presenter.perform { _ throws(OperationError) in
                            try await operations.undoConflictSide(forPath: row.path)
                        }
                    }
                case nil:
                    break
                }
            }
        )
    }
}

/// One of a conflicted file's actions, as VoiceOver offers it or the band
/// above its diff shows it.
struct ConflictFileAction {
    /// Which action it is.
    enum Kind: Equatable {
        case openInEditor, ours, theirs, undo
    }

    let kind: Kind
    let name: String
    let perform: () -> Void
}

extension ConflictFileRowContent {
    /// The file's buttons as VoiceOver's actions: Open in <Editor> (with an
    /// editor), the sides to pick while it needs the user, and Undo.
    func accessibilityActions(_ actions: ConflictFileRowActions) -> [ConflictFileAction] {
        var items: [ConflictFileAction] = []
        if case .markers = state, actions.isEditorAvailable {
            items.append(ConflictFileAction(kind: .openInEditor, name: actions.editorTitle, perform: actions.openInEditor))
        }
        return items + sideActions(actions, ours: oursLabel, theirs: theirsLabel) + undoAction(actions)
    }

    /// The buttons of the band above the file's diff: the sides to pick for
    /// the whole file while it needs the user (`includesSides`: not when
    /// its conflicts are drawn as blocks, whose headers have them), Open in
    /// <Editor> with an editor while it has markers, and Undo.
    func bandActions(_ actions: ConflictFileRowActions, includesSides: Bool = true) -> [ConflictFileAction] {
        var items = includesSides ? sideActions(actions, ours: oursVersionTitle, theirs: theirsVersionTitle) : []
        if case .markers = state, actions.isEditorAvailable {
            items.append(ConflictFileAction(kind: .openInEditor, name: actions.editorTitle, perform: actions.openInEditor))
        }
        return items + undoAction(actions)
    }

    /// The sides to pick, named `ours` and `theirs`, while the file needs
    /// the user.
    private func sideActions(_ actions: ConflictFileRowActions, ours: String?, theirs: String?) -> [ConflictFileAction] {
        var items: [ConflictFileAction] = []
        if isUnresolved {
            if let ours {
                items.append(ConflictFileAction(kind: .ours, name: ours) { actions.choose(.ours) })
            }
            if let theirs {
                items.append(ConflictFileAction(kind: .theirs, name: theirs) { actions.choose(.theirs) })
            }
        }
        return items
    }

    /// Undo, while there's a choice to take back.
    private func undoAction(_ actions: ConflictFileRowActions) -> [ConflictFileAction] {
        undo == nil ? [] : [ConflictFileAction(kind: .undo, name: "Undo", perform: actions.undo)]
    }
}

extension ConflictFileRowActions {
    /// "Open in Xcode", or "Open in External Editor".
    var editorTitle: String {
        "Open in \(editorName ?? "External Editor")"
    }
}

/// A conflicted file's buttons at the end of its row in the Changes list:
/// Open in <Editor> and the file's menu while it has conflict markers,
/// Resolve (pick a side) for a conflict without them, Undo once a side was
/// picked.
struct ConflictFileButtons: View {
    let content: ConflictFileRowContent
    let actions: ConflictFileRowActions

    var body: some View {
        trailing
            .fixedSize()
    }

    @ViewBuilder
    private var trailing: some View {
        switch content.state {
        case .markers:
            HStack(spacing: 0) {
                // The column is narrow: the editor's name is the button's
                // label for VoiceOver and its tooltip, and the menus say it.
                Button(action: actions.openInEditor) {
                    Label(actions.editorTitle, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.icon)
                .disabled(!actions.isEditorAvailable)
                .tooltip(actions.isEditorAvailable ? actions.editorTitle : "No editor configured in Settings ▸ Integrations")
                PullDownButton("File Resolution Options") {
                    menuItems
                } label: {
                    Label("File Resolution Options", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.icon)
                .fixedSize()
            }
        case .manual:
            if content.oursLabel != nil {
                PullDownButton("Resolve") {
                    sideItems
                } label: {
                    MenuCapsuleLabel("Resolve")
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .fixedSize()
            }
        case .resolved:
            if content.undo != nil {
                Button("Undo", action: actions.undo)
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
        }
    }

    /// The file's menu: open it, show it, pick a side, undo.
    private var menuItems: MenuContent {
        MenuContent { [content, actions] in
            if case .markers = content.state {
                MenuAction(actions.editorTitle, action: actions.openInEditor)
                    .disabled(!actions.isEditorAvailable)
            }
            MenuAction("Open with Default App", action: actions.openWithDefaultProgram)
            MenuAction("Show in Finder", action: actions.showInFinder)
            if content.isUnresolved, content.oursLabel != nil {
                MenuDivider()
                sideItems
            }
            if content.undo != nil {
                if !content.isUnresolved || content.oursLabel == nil {
                    MenuDivider()
                }
                MenuAction("Undo", action: actions.undo)
            }
        }
    }

    private var sideItems: MenuContent {
        MenuContent { [content, actions] in
            if let oursLabel = content.oursLabel {
                MenuAction(oursLabel) {
                    actions.choose(.ours)
                }
            }
            if let theirsLabel = content.theirsLabel {
                MenuAction(theirsLabel) {
                    actions.choose(.theirs)
                }
            }
        }
    }
}

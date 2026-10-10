// Ported in part from desktop/app/src/ui/lib/conflicts/unmerged-file.tsx
//
// A conflicted file in the Changes list: its state ("3 conflicts", "Manual
// conflict", "File does not exist on <branch>.", "No conflicts remaining",
// "Using the modified file from <branch>"), its buttons at the end of its
// row (Open in <Editor>, disabled without an editor, and the file's menu;
// the manual resolution menu; Undo), and their copy. The row is the
// Changes table's (FileRow.swift).

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
    /// What's left, at the end of the row.
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

    /// The state's tooltip: what's left, and while anything is, how to
    /// resolve it.
    public var help: String {
        guard isUnresolved else {
            return status
        }
        let sentence = status.hasSuffix(".") ? status : "\(status)."
        return "\(sentence) \(OperationPanelContent.hint)"
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

/// One of a conflicted file's actions, as VoiceOver offers it.
struct ConflictFileAction {
    let name: String
    let perform: () -> Void
}

extension ConflictFileRowContent {
    /// The file's buttons as VoiceOver's actions: Open in <Editor> (with an
    /// editor), the sides to pick while it needs the user, or Undo.
    func accessibilityActions(_ actions: ConflictFileRowActions) -> [ConflictFileAction] {
        var items: [ConflictFileAction] = []
        if case .markers = state, actions.isEditorAvailable {
            items.append(ConflictFileAction(name: actions.editorTitle, perform: actions.openInEditor))
        }
        if isUnresolved {
            if let oursLabel {
                items.append(ConflictFileAction(name: oursLabel) { actions.choose(.ours) })
            }
            if let theirsLabel {
                items.append(ConflictFileAction(name: theirsLabel) { actions.choose(.theirs) })
            }
        } else if case .resolved(isUndoable: true) = state {
            items.append(ConflictFileAction(name: "Undo") { actions.choose(nil) })
        }
        return items
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
                .help(actions.isEditorAvailable ? actions.editorTitle : "No editor configured in Settings ▸ Integrations")
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

    /// The file's menu: open it, show it, pick a side.
    @ViewBuilder
    private var menuItems: some View {
        if case .markers = content.state {
            Button(actions.editorTitle, action: actions.openInEditor)
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

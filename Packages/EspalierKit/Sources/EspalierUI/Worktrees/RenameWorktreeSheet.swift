// The Rename Worktree sheet: the name, starting from the folder's, and
// "Rename <name>", disabled until the name changes. `rename` moves the
// folder within its parent folder.
//
// The name is a folder's name only: one with "/" is refused here (it would
// move the worktree into another folder), and so is a name already taken
// next to it, which the model refuses too.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI

/// What the Rename Worktree sheet shows for the name typed.
nonisolated struct RenameWorktreeContent: Sendable, Equatable {
    /// The worktree's folder name now.
    var currentName: String
    /// The name typed.
    var name: String
    /// Why the name can't be used.
    var problem: String?
    var isRenaming = false

    /// Whether Rename can run: a new, usable name.
    var canRename: Bool {
        !JSCompat.trim(name).isEmpty && name != currentName && problem == nil && !isRenaming
    }

    /// "Rename <name>".
    var buttonTitle: String {
        "Rename \(currentName)"
    }

    /// The content for `name`, renaming the worktree at `path`.
    static func make(path: String, name: String, isRenaming: Bool, itemExists: (String) -> Bool = RenameWorktreeContent.itemExists) -> RenameWorktreeContent {
        let currentName = POSIXPath.basename(path)
        var problem: String?
        if name.contains("/") {
            problem = WorktreesModel.slashInNameMessage
        } else if !JSCompat.trim(name).isEmpty, name != currentName, itemExists(POSIXPath.join(POSIXPath.dirname(path), name)) {
            problem = "The name “\(name)” is already taken. Choose a different name."
        }
        return RenameWorktreeContent(currentName: currentName, name: name, problem: problem, isRenaming: isRenaming)
    }

    /// Whether anything, a dangling symbolic link included, is at `path`.
    static func itemExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// The Rename Worktree form.
struct RenameWorktreeForm: View {
    let content: RenameWorktreeContent
    @Binding var name: String
    var cancel: @MainActor () -> Void = {}
    var rename: @MainActor () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetScaffold("Rename Worktree", width: Metrics.Sheet.compactWidth) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                TextField("Name", text: $name, prompt: Text("Worktree name"))
                    .textFieldStyle(.capsule)
                    .focused($isFocused)
                    .onSubmit {
                        if content.canRename {
                            rename()
                        }
                    }
                if let problem = content.problem {
                    FieldMessage(problem, kind: .error)
                }
            }
        } buttons: {
            if content.isRenaming {
                ArcProgress(.small)
                    .accessibilityLabel("Renaming worktree")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(content.buttonTitle, action: rename)
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(!content.canRename)
        }
        .onAppear {
            isFocused = true
        }
    }
}

/// Renaming a worktree.
struct RenameWorktreeSheet: View {
    static let sheetID = "worktrees.rename"

    let repository: RepositoryModel
    let worktree: WorktreeEntry
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var name: String
    @State private var isRenaming = false

    init(repository: RepositoryModel, worktree: WorktreeEntry) {
        self.repository = repository
        self.worktree = worktree
        _name = State(initialValue: POSIXPath.basename(worktree.path))
    }

    var body: some View {
        RenameWorktreeForm(content: content, name: $name, cancel: { dismiss() }, rename: rename)
    }

    private var content: RenameWorktreeContent {
        RenameWorktreeContent.make(path: worktree.path, name: name, isRenaming: isRenaming)
    }

    private func rename() {
        guard content.canRename else {
            return
        }
        let worktrees = repository.worktrees
        let worktree = worktree
        let name = name
        isRenaming = true
        Task {
            let renamed: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await worktrees.rename(worktree, to: name)
            }
            isRenaming = false
            if renamed != nil {
                dismiss()
            }
        }
    }

    /// Shows the sheet for `worktree`.
    static func present(_ worktree: WorktreeEntry, repository: RepositoryModel, context: WindowContext) {
        context.modals.presentSheet(id: sheetID) {
            RenameWorktreeSheet(repository: repository, worktree: worktree)
        }
    }
}

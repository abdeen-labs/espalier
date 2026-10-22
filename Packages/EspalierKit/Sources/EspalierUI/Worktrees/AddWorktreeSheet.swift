// The Add Worktree sheet: Worktree Name, Local Path with Choose…, Branch
// Name with the branches as completions and the worktree's name as its
// placeholder, the hints "Will check out existing branch <b>." and "Will
// check out remote branch <b>." (`branchResolution(for:path:)`), "Worktree
// will be created at <path>.", and Create Worktree. `add` switches the
// window to the new worktree.
//
// It also says when a file or folder is already where the worktree would
// go, which git refuses, and when the Local Path isn't a full path (a
// leading `~` is the home folder).

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the Add Worktree sheet shows for what's typed.
nonisolated struct AddWorktreeContent: Sendable, Equatable {
    /// A line under a field.
    struct Message: Sendable, Equatable {
        var text: String
        var isError: Bool
    }

    /// The worktree's name: its folder's name.
    var name: String
    /// The folder it goes in.
    var directory: String
    /// The branch name typed.
    var branchName: String
    /// The branch it checks out when no branch name is typed: the
    /// worktree's name as a branch name.
    var branchPlaceholder: String
    /// What the branch name does: check out an existing or remote branch,
    /// or how the name will be saved.
    var branchMessage: Message?
    /// The branches whose names match what's typed, for completion.
    var suggestions: [String]
    /// The new worktree's folder, once there's a name and a folder.
    var path: String?
    /// Why the worktree can't go at `path`.
    var pathProblem: String?
    var isCreating = false

    /// Whether Create Worktree can run: a folder, a branch to check out,
    /// and nothing in the way.
    var canCreate: Bool {
        path != nil && pathProblem == nil && !(branchMessage?.isError ?? false)
            && !(sanitizedRefName(branchName).isEmpty && branchPlaceholder.isEmpty) && !isCreating
    }

    /// "Worktree will be created at <path>."
    var footer: String? {
        path.map { "Worktree will be created at \($0)." }
    }

    /// The content for what's typed, in `repository`.
    @MainActor
    static func make(
        name: String,
        directory: String,
        branchName: String,
        repository: RepositoryModel,
        isCreating: Bool,
        itemExists: (String) -> ItemAtPath = AddWorktreeContent.item(at:)
    ) -> AddWorktreeContent {
        let path = WorktreesModel.worktreePath(in: directory, name: name)
        let branchMessage = Self.branchMessage(
            name: name,
            branchName: branchName,
            resolution: repository.worktrees.branchResolution(for: branchName, path: path ?? name),
            branches: repository.gitState.branches.all
        )
        var pathProblem: String?
        if let path, !POSIXPath.isAbsolute(path) {
            pathProblem = AddWorktreeRequest.notFullPathMessage
        } else if let path {
            switch itemExists(path) {
            case .none, .emptyFolder:
                break
            case .folder, .file:
                pathProblem = "There's already a file or folder at \(path)."
            }
        }
        return AddWorktreeContent(
            name: name,
            directory: directory,
            branchName: branchName,
            branchPlaceholder: sanitizedRefName(name),
            branchMessage: branchMessage,
            suggestions: suggestions(for: branchName, in: repository.gitState.branches.all),
            path: path,
            pathProblem: pathProblem,
            isCreating: isCreating
        )
    }

    /// The message under Branch Name: an error when nothing of the branch's
    /// name is valid (the name typed, or the worktree's name when none is
    /// typed), or when the local branch the worktree makes can't be kept
    /// beside `branches`' local branches (`refNameConflict`); else what the
    /// name checks out (`resolution`'s hint), or how it will be saved.
    static func branchMessage(
        name: String,
        branchName: String,
        resolution: WorktreeBranchResolution?,
        branches: [Branch]
    ) -> Message? {
        let sanitized = sanitizedRefName(branchName)
        if !branchName.isEmpty, sanitized.isEmpty {
            return Message(text: "\(branchName) is not a valid name.", isError: true)
        }
        if branchName.isEmpty, !JSCompat.trim(name).isEmpty, sanitizedRefName(name).isEmpty {
            return Message(text: "\(name) is not a valid name.", isError: true)
        }
        // The local branch the worktree makes: a new branch, or a remote
        // branch's.
        let newBranchName: String? = switch resolution {
        case .new, .remote: resolution?.branchName
        case .existing, nil: nil
        }
        if let newBranchName,
           let conflict = refNameConflict(newBranchName, among: branches.lazy.filter { $0.type == .local }.map(\.name)) {
            return Message(
                text: conflict.isSameName
                    ? "A branch named \(conflict.existingName) already exists."
                    : "A branch named \(conflict.existingName) already exists, so \(newBranchName) can't be used.",
                isError: true
            )
        }
        if let hint = resolution?.hint {
            return Message(text: hint, isError: false)
        }
        if !branchName.isEmpty, sanitized != branchName {
            return Message(text: "Will be created as \(sanitized).", isError: false)
        }
        return nil
    }

    /// The branch names that contain `text` (all of them for none), local
    /// branches first, at most ten.
    static func suggestions(for text: String, in branches: [Branch]) -> [String] {
        let matching = branches.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
        let ordered = matching.filter { $0.type == .local } + matching.filter { $0.type != .local }
        return Array(ordered.map(\.name).prefix(10))
    }

    /// What's at a path.
    enum ItemAtPath: Sendable, Equatable {
        case none, emptyFolder, folder, file
    }

    /// What's at `path` on disk.
    static func item(at path: String) -> ItemAtPath {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .none
        }
        guard isDirectory.boolValue else {
            return .file
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.isEmpty ? .emptyFolder : .folder
    }
}

/// The Add Worktree form.
struct AddWorktreeForm: View {
    let content: AddWorktreeContent
    @Binding var name: String
    @Binding var directory: String
    @Binding var branchName: String
    var choose: @MainActor () -> Void = {}
    var cancel: @MainActor () -> Void = {}
    var create: @MainActor () -> Void = {}
    @FocusState private var isNameFocused: Bool

    var body: some View {
        SheetScaffold("Add Worktree") {
            Form {
                // The labels in the form's column; the fields are capsules.
                LabeledContent("Worktree Name") {
                    TextField("Worktree Name", text: $name, prompt: Text("Worktree name").fieldPrompt())
                        .labelsHidden()
                        .focused($isNameFocused)
                }
                LabeledContent("Local Path") {
                    HStack(spacing: Metrics.insetSmall) {
                        TextField("Local Path", text: $directory, prompt: Text("Folder").fieldPrompt())
                            .labelsHidden()
                        Button("Choose…", action: choose)
                            .buttonStyle(.quiet)
                    }
                }
                if let problem = content.pathProblem {
                    FieldMessage(problem, kind: .error)
                }
                LabeledContent("Branch Name") {
                    TextField("Branch Name", text: $branchName, prompt: Text(content.branchPlaceholder.isEmpty ? "Branch name" : content.branchPlaceholder).fieldPrompt())
                        .labelsHidden()
                        .textFieldSuggestions(content.suggestions, text: branchName)
                }
                if let message = content.branchMessage {
                    FieldMessage(message.text, kind: message.isError ? .error : .note)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
            if let footer = content.footer {
                Text(footer)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } buttons: {
            if content.isCreating {
                ArcProgress(.small)
                    .accessibilityLabel("Creating worktree")
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button("Create Worktree", action: create)
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(!content.canCreate)
        }
        .onAppear {
            isNameFocused = true
        }
    }
}

/// Adding a worktree.
struct AddWorktreeSheet: View {
    static let sheetID = "worktrees.add"

    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var name: String
    @State private var directory: String
    @State private var branchName: String
    @State private var isCreating = false

    init(repository: RepositoryModel, name: String = "", directory: String, branchName: String = "") {
        self.repository = repository
        _name = State(initialValue: name)
        _directory = State(initialValue: directory)
        _branchName = State(initialValue: branchName)
    }

    var body: some View {
        AddWorktreeForm(
            content: content,
            name: $name,
            directory: $directory,
            branchName: $branchName,
            choose: chooseDirectory,
            cancel: { dismiss() },
            create: create
        )
    }

    private var content: AddWorktreeContent {
        AddWorktreeContent.make(name: name, directory: directory, branchName: branchName, repository: repository, isCreating: isCreating)
    }

    private func create() {
        let content = content
        guard content.canCreate, let path = content.path else {
            return
        }
        let worktrees = repository.worktrees
        let request = AddWorktreeRequest(path: path, branchName: branchName.isEmpty ? nil : branchName)
        isCreating = true
        Task {
            let added = await context.presenter.perform { _ throws(OperationError) in
                try await worktrees.add(request)
            }
            isCreating = false
            // A new worktree whose submodules couldn't be updated is still
            // there, and the window is at it: the error says why.
            if added != nil || Self.isSamePath(repository.record.path, path) {
                dismiss()
            }
        }
    }

    /// Whether two paths are the same folder, symbolic links resolved (git
    /// lists real paths).
    static func isSamePath(_ first: String, _ second: String) -> Bool {
        func resolved(_ path: String) -> String {
            guard let real = Darwin.realpath(path, nil) else {
                return POSIXPath.normalize(path)
            }
            defer { free(real) }
            return String(cString: real)
        }
        return resolved(first) == resolved(second)
    }

    /// Choose…: a folder for the worktree.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !directory.isEmpty {
            panel.directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                directory = url.path(percentEncoded: false)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Shows the sheet, prefilled for checking out `branch` (a branch's or a
    /// pull request's "Check Out in New Worktree…").
    static func present(branch: String?, pullRequest: Int?, repository: RepositoryModel, context: WindowContext) {
        let initial = initialValues(branch: branch, pullRequest: pullRequest, repository: repository)
        context.modals.presentSheet(id: sheetID) {
            AddWorktreeSheet(repository: repository, name: initial.name, directory: initial.directory, branchName: initial.branchName)
        }
    }

    /// What the sheet starts with: for a branch, the branch and the name
    /// "<repository>-<branch>" ("<repository>-<number>" for a pull request),
    /// with a branch's "/" as "-" so the worktree's folder isn't nested in
    /// another; the folder new worktrees go in.
    static func initialValues(branch: String?, pullRequest: Int?, repository: RepositoryModel) -> (name: String, directory: String, branchName: String) {
        let worktrees = repository.worktrees
        var name = ""
        if let pullRequest {
            name = worktrees.suggestedName(forPullRequest: pullRequest)
        } else if let branch {
            if let match = repository.gitState.branches.all.first(where: { $0.name == branch }) {
                name = worktrees.suggestedName(for: match)
            } else {
                name = "\(repository.record.name)-\(branch)"
            }
        }
        let directory = worktrees.defaultDirectory ?? POSIXPath.join(NSHomeDirectory(), "Developer")
        return (name.replacingOccurrences(of: "/", with: "-"), directory, branch ?? "")
    }
}

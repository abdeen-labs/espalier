// Creating a tag: a name, cleaned up as a ref name ("Will be created as
// …"), its checks (`tagNameError`: too long, already exists), and the
// previous tags that match what's typed. It sits in the shared
// `SheetScaffold`.

import EspalierCore
import GitKit
import SwiftUI

/// What the tag sheet shows for the name typed.
nonisolated struct CreateTagContent: Sendable, Equatable {
    /// The name typed.
    var name: String
    /// The name the tag gets: the typed one, cleaned up as a ref name.
    var sanitizedName: String
    /// Why the name can't be used, if it can't.
    var error: String?
    /// The latest existing tags containing the name typed, at most three.
    var previousTags: [String]
    var isCreating = false

    /// Whether the tag can be created.
    var canCreate: Bool {
        !sanitizedName.isEmpty && error == nil && !isCreating
    }

    /// The latest three of `tags` that contain `name` (all of them for an
    /// empty name), by version.
    static func previousTags(_ tags: [String], matching name: String) -> [String] {
        let matching = name.isEmpty ? tags : tags.filter { $0.contains(name) }
        return Array(matching.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.prefix(3))
    }
}

/// The tag sheet's content.
struct CreateTagForm: View {
    let content: CreateTagContent
    @Binding var name: String
    var cancel: () -> Void = {}
    var create: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetScaffold("Create Tag", width: Metrics.Sheet.compactWidth) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                TextField("Name", text: $name, prompt: Text("v1.0.0"))
                    .textFieldStyle(.capsule)
                    .focused($isFocused)
                    .onSubmit {
                        if content.canCreate {
                            create()
                        }
                    }
                if let error = content.error {
                    FieldMessage(error, kind: .error)
                } else if !content.name.isEmpty, content.sanitizedName != content.name {
                    FieldMessage("Will be created as \(content.sanitizedName)", kind: .note)
                }
            }
            VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                SectionLabel("Previous Tags")
                if content.previousTags.isEmpty {
                    Text(content.name.isEmpty ? "No tags yet" : "No tags contain \u{201C}\(content.name)\u{201D}")
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                } else {
                    HStack(spacing: Metrics.RefCapsule.spacing) {
                        ForEach(content.previousTags, id: \.self) { tag in
                            RefCapsule(RefCapsuleContent(name: tag, kind: .tag))
                        }
                    }
                }
            }
        } buttons: {
            SheetButtons(
                "Create Tag",
                isConfirmDisabled: !content.canCreate,
                isWorking: content.isCreating,
                cancel: cancel,
                confirm: create
            )
        }
        .onAppear {
            isFocused = true
        }
    }
}

/// Creating a tag on a commit.
struct CreateTagSheet: View {
    static let sheetID = "history.createTag"

    let repository: RepositoryModel
    let sha: String
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var name = ""
    @State private var isCreating = false

    var body: some View {
        CreateTagForm(content: content, name: $name, cancel: { dismiss() }, create: create)
    }

    private var content: CreateTagContent {
        let sanitized = sanitizedRefName(name)
        let tags = Array((repository.gitState.tags ?? [:]).keys)
        return CreateTagContent(
            name: name,
            sanitizedName: sanitized,
            error: sanitized.isEmpty ? nil : repository.branches.tagNameError(sanitized),
            previousTags: CreateTagContent.previousTags(tags, matching: name),
            isCreating: isCreating
        )
    }

    private func create() {
        let name = sanitizedRefName(name)
        let branches = repository.branches
        let sha = sha
        isCreating = true
        Task {
            let created: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await branches.createTag(name, at: sha)
            }
            isCreating = false
            if created != nil {
                dismiss()
            }
        }
    }

    /// Shows the sheet for a tag on `sha`.
    static func present(at sha: String, repository: RepositoryModel, context: WindowContext) {
        context.modals.presentSheet(id: sheetID) {
            CreateTagSheet(repository: repository, sha: sha)
        }
    }
}

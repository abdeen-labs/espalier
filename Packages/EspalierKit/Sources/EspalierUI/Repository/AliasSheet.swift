// Create Alias… and Change Alias…: the field starts with the alias or the
// name, the note about GitHub shows for GitHub repositories, and an empty
// alias can't be saved.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the alias sheet shows.
nonisolated struct AliasContent: Sendable, Equatable {
    /// "owner/name" for a GitHub repository, else the name.
    var repositoryName: String
    /// Whether the repository has an alias now: Change, else Create.
    var hasAlias: Bool
    var isGitHubRepository: Bool

    private var verb: String {
        hasAlias ? "Change" : "Create"
    }

    var title: String {
        "\(verb) Repository Alias"
    }

    var message: String {
        "Choose a new alias for the repository \u{201C}\(repositoryName)\u{201D}."
    }

    var confirmButton: String {
        "\(verb) Alias"
    }

    /// Shown for GitHub repositories.
    static let gitHubNote = "This doesn't change the repository's name on GitHub."

    /// Whether `alias` can be saved: not empty.
    static func canSave(_ alias: String) -> Bool {
        !alias.isEmpty
    }
}

/// The alias sheet's form.
struct AliasForm: View {
    let content: AliasContent
    @Binding var alias: String
    var cancel: () -> Void = {}
    var save: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetScaffold(content.title, message: content.message, width: Metrics.Sheet.compactWidth) {
            Form {
                // The label in the form's column; the field is a capsule.
                LabeledContent("Alias") {
                    TextField("Alias", text: $alias)
                        .labelsHidden()
                        .focused($isFocused)
                        .onSubmit {
                            if AliasContent.canSave(alias) {
                                save()
                            }
                        }
                }
                if content.isGitHubRepository {
                    FieldMessage(AliasContent.gitHubNote, kind: .note)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        } buttons: {
            SheetButtons(content.confirmButton, isConfirmDisabled: !AliasContent.canSave(alias), cancel: cancel, confirm: save)
        }
        .onAppear {
            isFocused = true
        }
    }
}

/// Creating or changing a repository's alias.
struct AliasSheet: View {
    static let sheetID = "repository.alias"

    let repositoryID: RepositoryID
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss
    @State private var alias: String

    init(record: RepositoryRecord) {
        repositoryID = record.id
        _alias = State(initialValue: record.alias ?? record.name)
    }

    var body: some View {
        if let record = context.app.record(repositoryID) {
            AliasForm(content: Self.content(for: record), alias: $alias, cancel: { dismiss() }, save: save)
        }
    }

    static func content(for record: RepositoryRecord) -> AliasContent {
        AliasContent(
            repositoryName: record.gitHubRepository?.fullName ?? record.name,
            hasAlias: record.alias != nil,
            isGitHubRepository: record.gitHubRepository != nil
        )
    }

    private func save() {
        context.app.setAlias(alias, for: repositoryID)
        dismiss()
    }

    /// Shows the sheet for a repository.
    static func present(for id: RepositoryID, in context: WindowContext) {
        guard let record = context.app.record(id) else {
            return
        }
        context.state.isRepositoryPopoverPresented = false
        context.modals.presentSheet(id: sheetID) {
            AliasSheet(record: record)
        }
    }
}

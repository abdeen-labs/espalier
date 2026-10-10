// "How are you planning to use this fork?", asked after cloning a fork. It's
// the fork settings step (`CreateForkView`'s `.settings`, which the Create
// Fork sheet ends with), so both ask the same way. Continue saves the choice
// (`setForkContributionTarget`); Escape saves nothing. Repository Settings'
// Fork Behavior shows the same choice.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// A fork's names, and how it's used.
nonisolated struct ForkSettingsContent: Sendable, Equatable {
    /// The parent's `owner/name`.
    var parent: String
    /// The fork's `owner/name`.
    var fork: String
    var target: ForkContributionTarget

    /// The repository the choice points everything at.
    var targetName: String {
        target == .fork ? fork : parent
    }

    @MainActor
    init?(record: RepositoryRecord, target: ForkContributionTarget? = nil) {
        guard isRepositoryWithForkedGitHubRepository(record), let gitHubRepository = record.gitHubRepository,
              let parent = gitHubRepository.parent else {
            return nil
        }
        self.init(parent: parent.fullName, fork: gitHubRepository.fullName, target: target ?? getForkContributionTarget(record))
    }

    init(parent: String, fork: String, target: ForkContributionTarget) {
        self.parent = parent
        self.fork = fork
        self.target = target
    }
}

/// The two choices with their titles and descriptions, for Repository
/// Settings.
struct ForkTargetPicker: View {
    let content: ForkSettingsContent
    @Binding var target: ForkContributionTarget
    var parentTitle = "To contribute to the parent repository"
    var label = "I'll be using this fork…"

    var body: some View {
        ChoiceList(label, selection: $target, choices: [
            ChoiceListItem(parentTitle, styledDescription: Self.helpsContribute(to: content.parent), value: .parent),
            ChoiceListItem("For my own purposes", styledDescription: Self.helpsContribute(to: content.fork), value: .fork),
        ])
    }

    /// "Espalier helps you contribute to **owner/name**."
    private static func helpsContribute(to repository: String) -> AttributedString {
        var name = AttributedString(repository)
        name.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("Espalier helps you contribute to ") + name + AttributedString(".")
    }
}

/// "How are you planning to use this fork?"
struct ChooseForkSettingsSheet: View {
    static let sheetID = "repository.forkSettings"

    let repositoryID: RepositoryID
    let content: ForkSettingsContent
    @State private var target: ForkContributionTarget
    @Environment(WindowContext.self) private var context
    @Environment(\.dismissModal) private var dismiss

    init(repositoryID: RepositoryID, content: ForkSettingsContent) {
        self.repositoryID = repositoryID
        self.content = content
        _target = State(initialValue: content.target)
    }

    var body: some View {
        CreateForkView(
            step: .settings(parent: content.parent, fork: content.fork, target: target),
            target: $target,
            cancel: { dismiss() },
            fork: {},
            open: { _ in },
            finish: {
                context.app.setForkContributionTarget(target, for: repositoryID)
                dismiss()
            }
        )
        .onExitCommand {
            dismiss()
        }
    }

    /// Asks how the fork `id` will be used; nothing for a repository that
    /// isn't a fork.
    static func present(for id: RepositoryID, in context: WindowContext) {
        guard let record = context.app.record(id), let content = ForkSettingsContent(record: record) else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            ChooseForkSettingsSheet(repositoryID: id, content: content)
        }
    }
}

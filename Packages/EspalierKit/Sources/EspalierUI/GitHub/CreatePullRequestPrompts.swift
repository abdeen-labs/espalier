// Create Pull Request's questions, as alerts: an unpublished branch asks
// "Publish Branch?" [Cancel] [Publish Branch]; unpushed commits ask "Push
// Local Changes?" [Cancel] [Create Without Pushing] [Push Commits]. Then
// `prepareToCreatePullRequest(base:choice:)` is ready and the Create Pull
// Request sheet opens for the branch; without an account for the
// repository's server, GitHub's form opens in the browser instead
// (fork-aware). A repository without a remote is published first.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// Create Pull Request, with its questions.
@MainActor
enum CreatePullRequestPrompts {
    /// The alert for what has to happen first.
    nonisolated static func alert(for step: CreatePullRequestStep) -> AlertContent {
        var buttons = [AlertContent.Button(step.confirmButton, role: .primary)]
        if let alternative = step.alternativeButton {
            buttons.append(AlertContent.Button(alternative, role: .secondary))
        }
        buttons.append(AlertContent.Button("Cancel", role: .cancel))
        return AlertContent(title: step.title, message: step.message, buttons: buttons)
    }

    /// The choice for the button the user chose; nil for Cancel.
    nonisolated static func choice(for step: CreatePullRequestStep, buttonIndex: Int) -> CreatePullRequestChoice? {
        switch (step, buttonIndex) {
        case (_, 0): .pushFirst
        case (.pushCommits, 1): .createWithoutPushing
        default: nil
        }
    }

    /// Opens the Create Pull Request sheet for a pull request from the
    /// current branch into `base` (the default branch when nil), asking
    /// first when the branch must be published or has commits to push.
    static func run(base: Branch? = nil, in context: WindowContext) async {
        guard let repository = context.repository else {
            return
        }
        var choice: CreatePullRequestChoice?
        while true {
            let answered = choice
            let outcome = await context.presenter.perform { _ throws(OperationError) in
                try await repository.gitHub.prepareToCreatePullRequest(base: base, choice: answered)
            }
            switch outcome {
            case .choiceRequired(let step)?:
                guard answered == nil else {
                    return
                }
                let response = await context.modals.alert(alert(for: step))
                guard let next = Self.choice(for: step, buttonIndex: response.buttonIndex) else {
                    return
                }
                choice = next
            case .publishRepositoryRequired?:
                context.actions.perform(.publishRepository)
                return
            case .ready(let head)?:
                CreatePullRequestSheet.present(head: head, base: base, repository: repository, in: context)
                return
            case .openedInBrowser?, nil:
                return
            }
        }
    }
}

// Repository Settings' Git Config pane, a form: use the global config, or a
// local one with its own name and email (`GitAuthorForm`); the global
// values show, dimmed, while the global config is in use. The email offers
// the repository's account's addresses and Other, with the attribution
// check under Other.

import EspalierCore
import GitHubKit
import SwiftUI

/// The Git Config pane.
struct GitConfigPane: View {
    @Bindable var model: RepositorySettingsModel

    var body: some View {
        Form {
            LabeledContent("For this repository") {
                RadioList(
                    "For this repository",
                    selection: $model.gitConfigLocation,
                    choices: GitConfigLocation.allCases.map { ChoiceListItem($0.title, value: $0) }
                )
            }
            if model.gitConfigLocation == .global {
                let name = model.gitAuthor?.globalName ?? ""
                let email = model.gitAuthor?.globalEmail ?? ""
                GitAuthorForm(
                    name: .constant(name),
                    emailSelection: .constant(.showing(email, choices: model.authorEmailChoices)),
                    otherEmail: .constant(email),
                    emailChoices: model.authorEmailChoices
                )
                .disabled(true)
            } else {
                GitAuthorForm(
                    name: $model.authorName,
                    nameProblem: model.authorNameProblem,
                    emailSelection: Binding {
                        model.authorEmailSelection
                    } set: { selection in
                        model.selectAuthorEmail(selection)
                    },
                    otherEmail: $model.authorEmail,
                    emailChoices: model.authorEmailChoices,
                    attribution: model.authorEmailAttribution
                )
            }
        }
        .formStyle(.columns)
        .disabled(!model.isLoaded)
    }
}

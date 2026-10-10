// Repository Settings' Git Config pane: use the global config, or a local
// one with its own name and email; the global values show, dimmed, while
// the global config is in use. The email offers the repository's account's
// addresses and Other, with the attribution check under Other.

import EspalierCore
import GitHubKit
import SwiftUI

/// The Git Config pane.
struct GitConfigPane: View {
    @Bindable var model: RepositorySettingsModel

    var body: some View {
        let isGlobal = model.gitConfigLocation == .global
        let accounts = model.account.map { [$0] } ?? []
        VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("For this repository:")
                ChoiceList(
                    "For this repository:",
                    selection: $model.gitConfigLocation,
                    choices: GitConfigLocation.allCases.map { ChoiceListItem($0.title, value: $0) }
                )
            }

            Form {
                // The labels in the form's column; the fields are capsules.
                LabeledContent("Name") {
                    TextField("Name", text: isGlobal ? .constant(model.gitAuthor?.globalName ?? "") : $model.authorName)
                        .labelsHidden()
                        .disabled(isGlobal)
                }
                if let problem = model.authorNameProblem {
                    SheetMessage(problem, kind: .error)
                }
                GitConfigEmailField(
                    email: isGlobal ? .constant(model.gitAuthor?.globalEmail ?? "") : $model.authorEmail,
                    accounts: accounts,
                    isDisabled: isGlobal
                )
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        }
        .disabled(!model.isLoaded)
    }
}

/// The email: the accounts' addresses and Other, or a field without them;
/// under Other, whether commits will be attributed to the account.
struct GitConfigEmailField: View {
    @Binding var email: String
    let accounts: [Account]
    var isDisabled = false
    @State private var choosesOther = false

    var body: some View {
        let choices = gitAuthorEmailChoices(for: accounts)
        if choices.isEmpty {
            LabeledContent("Email") {
                TextField("Email", text: $email)
                    .labelsHidden()
                    .disabled(isDisabled)
            }
            attribution
        } else {
            let isOther = choosesOther || !email.isEmpty && !isGitAuthorEmailChoice(email, accounts: accounts)
            Picker("Email", selection: Binding(
                get: { isOther ? nil : choices.first { $0.email.lowercased() == email.lowercased() }?.email ?? choices.first?.email },
                set: { choice in
                    if let choice {
                        choosesOther = false
                        email = choice
                    } else {
                        choosesOther = true
                    }
                }
            )) {
                ForEach(choices, id: \.email) { choice in
                    Text([choice.email, choice.accountSuffix].compactMap(\.self).joined(separator: " ")).tag(Optional(choice.email))
                }
                Divider()
                Text("Other").tag(String?.none)
            }
            .disabled(isDisabled)
            if isOther {
                LabeledContent("Other Email") {
                    TextField("Other Email", text: $email, prompt: Text(verbatim: "name@example.com"))
                        .labelsHidden()
                        .disabled(isDisabled)
                }
                attribution
            }
        }
    }

    @ViewBuilder
    private var attribution: some View {
        if !isDisabled, let attribution = gitEmailAttribution(email, accounts: accounts) {
            SheetMessage(attribution.message, kind: attribution.isAttributable ? .success : .warning)
        }
    }
}

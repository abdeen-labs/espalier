// The author's name and email, as desktop's GitConfigUserForm
// (app/src/ui/lib/git-config-user-form.tsx) shows them, wherever Espalier
// asks for them: Settings ▸ Git, Repository Settings ▸ Git Config, and the
// welcome flow's Configure Git. The name; the email as a pop-up of the
// accounts' addresses and Other, with the field for Other under it, or a
// field alone without any addresses; the name's problem; and, under a typed
// address, whether commits with it are attributed to an account. Settings
// lays the two out as its rows, sheets and the welcome flow as a form's
// rows. The owner holds the values, writes them, and says what's wrong.

import EspalierCore
import GitHubKit
import SwiftUI

/// The email pop-up's choice.
nonisolated enum GitAuthorEmailSelection: Hashable, Sendable {
    /// No email is configured (offered only then).
    case none
    /// One of the accounts' addresses.
    case account(String)
    /// Another address, typed in the field.
    case other

    /// The choice that shows `email`: the account address it is, matched
    /// without regard to case; None for no address; Other for another.
    static func showing(_ email: String, choices: [GitAuthorEmailChoice]) -> GitAuthorEmailSelection {
        guard !email.isEmpty else {
            return .none
        }
        let needle = email.lowercased()
        if let choice = choices.first(where: { $0.email.lowercased() == needle }) {
            return .account(choice.email)
        }
        return .other
    }
}

extension GitAuthorEmailChoice {
    /// The pop-up's item: the address, with the account's kind when the
    /// user has both kinds of account.
    var title: String {
        accountSuffix.map { "\(email) \($0)" } ?? email
    }
}

/// The author's name and email: two rows.
struct GitAuthorForm: View {
    /// How the rows are laid out.
    enum Layout {
        /// Settings rows: the title on the left, the control on the right.
        case settings
        /// A form's rows: the label in the form's column.
        case form
    }

    /// A field the user commits.
    enum Field: Hashable {
        case name, email
    }

    @Binding var name: String
    /// The empty name field's placeholder.
    var namePrompt = "Your Name"
    /// Why the name can't be saved.
    var nameProblem: String?
    @Binding var emailSelection: GitAuthorEmailSelection
    /// The email field: the address typed under Other, or alone without
    /// the pop-up.
    @Binding var otherEmail: String
    /// The addresses the pop-up offers; without any, the email is a field.
    let emailChoices: [GitAuthorEmailChoice]
    /// Whether commits with the typed address are attributed to an account.
    var attribution: GitEmailAttribution?
    /// Whether the author is an account's: the name and an address without
    /// a pop-up show as text, and the pop-up offers only the account's
    /// addresses.
    var isAccountAuthor = false
    var layout: Layout = .form
    /// A field was committed: Return was pressed in it, or it lost focus.
    var onCommit: (Field) -> Void = { _ in }

    @FocusState private var focus: Field?

    var body: some View {
        row("Name") {
            if isAccountAuthor {
                Text(name)
                    .foregroundStyle(.text)
                    .textSelection(.enabled)
                    .authorControlWidth(layout)
            } else {
                TextField("Name", text: $name, prompt: Text(verbatim: namePrompt))
                    .labelsHidden()
                    .textFieldStyle(.capsule)
                    .authorControlWidth(layout)
                    .focused($focus, equals: .name)
                    .onSubmit { onCommit(.name) }
                    .onChange(of: focus == .name) { wasFocused, isFocused in
                        if wasFocused, !isFocused {
                            onCommit(.name)
                        }
                    }
            }
        } footer: {
            if let nameProblem {
                FieldMessage(nameProblem, kind: .error)
            }
        }
        row("Email", description: emailDescription) {
            VStack(alignment: layout == .settings ? .trailing : .leading, spacing: Metrics.Sheet.groupSpacing) {
                if showsPopUp {
                    emailPopUp
                }
                if showsField {
                    emailField
                }
            }
        } footer: {
            if let attribution {
                FieldMessage(attribution.message, kind: attribution.isAttributable ? .success : .warning)
            }
        }
    }

    /// Whether the email is a pop-up (there are addresses to offer).
    private var showsPopUp: Bool {
        !emailChoices.isEmpty
    }

    /// Whether the email field shows: for Other, or alone.
    private var showsField: Bool {
        !showsPopUp || emailSelection == .other
    }

    /// Settings' line under the email's title: what the address is for, and
    /// where the pop-up's addresses come from.
    private var emailDescription: String? {
        guard layout == .settings else {
            return nil
        }
        return showsPopUp
            ? "Used for your commits. Your GitHub accounts' addresses are offered."
            : "Used for your commits."
    }

    private var emailPopUp: some View {
        CapsulePopUp("Email", selection: $emailSelection, title: emailTitle) {
            if emailSelection == .none {
                MenuChoice("None", value: GitAuthorEmailSelection.none)
            }
            for choice in emailChoices {
                MenuChoice(choice.title, value: GitAuthorEmailSelection.account(choice.email))
            }
            if case .account(let email) = emailSelection, !emailChoices.contains(where: { $0.email == email }) {
                MenuChoice(email, value: GitAuthorEmailSelection.account(email))
            }
            if !isAccountAuthor {
                MenuDivider()
                MenuChoice("Other", value: GitAuthorEmailSelection.other)
            }
        }
        .authorControlWidth(layout)
    }

    /// The email pop-up's title: the chosen item's.
    private var emailTitle: String {
        switch emailSelection {
        case .none:
            "None"
        case .other:
            "Other"
        case .account(let email):
            emailChoices.first { $0.email == email }?.title ?? email
        }
    }

    @ViewBuilder
    private var emailField: some View {
        if isAccountAuthor {
            Text(otherEmail)
                .foregroundStyle(.text)
                .textSelection(.enabled)
                .authorControlWidth(layout)
        } else {
            TextField(showsPopUp ? "Other Email" : "Email", text: $otherEmail, prompt: Text(verbatim: "name@example.com"))
                .labelsHidden()
                .textFieldStyle(.capsule)
                .authorControlWidth(layout)
                .focused($focus, equals: .email)
                .onSubmit { onCommit(.email) }
                .onChange(of: focus == .email) { wasFocused, isFocused in
                    if wasFocused, !isFocused {
                        onCommit(.email)
                    }
                }
                .barTransition()
        }
    }

    /// A row: a Settings row, or a form's row with the footer under the
    /// control in the form's column.
    @ViewBuilder
    private func row<Control: View, Footer: View>(
        _ title: String,
        description: String? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        switch layout {
        case .settings:
            SettingsRow(title, description: description, labelsControl: true, control: control, footer: footer)
        case .form:
            LabeledContent(title) {
                VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                    control()
                    footer()
                }
            }
        }
    }
}

private extension View {
    /// A control's width: the rows' control width in Settings; in a form,
    /// the form's column, as wide as the fields beside it.
    @ViewBuilder
    func authorControlWidth(_ layout: GitAuthorForm.Layout) -> some View {
        switch layout {
        case .settings: settingsControlWidth()
        case .form: frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

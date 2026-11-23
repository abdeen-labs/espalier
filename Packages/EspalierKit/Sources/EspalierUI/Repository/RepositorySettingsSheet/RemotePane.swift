// Repository Settings' Remotes pane: the user's remotes, the current one
// first, each with its URL to edit and a button that takes it off the list;
// Add Remote, which adds a row with a name and a URL to fill in; and for a
// GitHub repository, its account: the accounts signed in to its server,
// None, and the one it has when that isn't signed in (listed, not to choose
// again). Without a remote, Publish and Add Remote. Nothing changes in the
// repository until Save.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// The account the Remotes pane shows, for a GitHub repository.
struct RemotePaneAccount {
    /// The accounts signed in to the repository's server.
    let accounts: [Account]
    /// The repository's account, when it isn't signed in.
    let signedOutLogin: String?
    /// The login chosen (nil: none).
    @Binding var login: String?
}

/// The Remotes pane.
struct RemotePane: View {
    /// The remotes, and those being added.
    @Binding var remotes: [RemoteDraft]
    /// Whether a remote of the repository's was taken off the list.
    var hasRemovedRemotes = false
    /// What about the remotes stops Save.
    var problem: String?
    var account: RemotePaneAccount?
    var add: () -> Void = {}
    var remove: (RemoteDraft.ID) -> Void = { _ in }
    var publish: () -> Void = {}

    var body: some View {
        if remotes.isEmpty, !hasRemovedRemotes {
            SheetCallToAction(systemImage: "icloud.and.arrow.up", message: "Publish your repository to GitHub, or add a remote it already has elsewhere.") {
                HStack(spacing: Metrics.insetSmall) {
                    Button("Publish", action: publish)
                        .buttonStyle(.quiet)
                    Button("Add Remote", action: add)
                        .buttonStyle(.quiet)
                }
            }
        } else {
            Form {
                // The labels in the form's column; the fields are capsules.
                ForEach($remotes) { $remote in
                    LabeledContent(remote.isNew ? "New Remote" : remote.name) {
                        HStack(spacing: Metrics.insetSmall) {
                            if remote.isNew {
                                TextField("Name", text: $remote.name, prompt: Text("Name").fieldPrompt())
                                    .labelsHidden()
                                    .autocorrectionDisabled(true)
                                    .frame(width: Metrics.RemotesPane.nameWidth)
                            }
                            TextField(remote.isNew ? "URL" : "Remote Repository (\(remote.name)) URL", text: $remote.url, prompt: Text("Remote URL").fieldPrompt())
                                .labelsHidden()
                                .autocorrectionDisabled(true)
                            Button {
                                remove(remote.id)
                            } label: {
                                Label(remote.isNew ? "Remove New Remote" : "Remove \(remote.name)", systemImage: "minus.circle")
                            }
                            .buttonStyle(.icon)
                            .tooltip(remote.isNew ? "Remove" : "Remove \(remote.name)")
                        }
                    }
                }
                LabeledContent("") {
                    Button("Add Remote", systemImage: "plus", action: add)
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let problem {
                    FieldMessage(problem, kind: .error)
                }
                if hasRemovedRemotes {
                    FieldMessage("Removing a remote also removes its remote branches from this repository. Your local branches and commits stay.", kind: .note)
                }
                if let account {
                    LabeledContent("Account") {
                        CapsulePopUp("Account", selection: account.$login, title: accountTitle(account)) {
                            MenuChoice("None", value: String?.none)
                            if let signedOut = account.signedOutLogin {
                                MenuChoice("@\(signedOut) (Signed Out)", value: Optional(signedOut))
                                    .disabled(true)
                            }
                            for choice in account.accounts {
                                MenuChoice("@\(choice.login)", value: Optional(choice.login), subtitle: AccountPicker.subtitle(choice))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    FieldMessage("The account for GitHub's API and HTTPS Git. Your commits' author doesn't change.", kind: .note)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        }
    }

    /// The pop-up's title: the account chosen, "(Signed Out)" when it isn't
    /// signed in, or None.
    private func accountTitle(_ account: RemotePaneAccount) -> String {
        guard let login = account.login else {
            return "None"
        }
        let signedIn = account.accounts.contains { JSCompat.caseInsensitiveEquals($0.login, login) }
        return signedIn ? "@\(login)" : "@\(login) (Signed Out)"
    }
}

extension Metrics {
    /// Repository Settings' Remotes pane.
    public enum RemotesPane {
        /// A new remote's name field.
        public static let nameWidth: CGFloat = 120
    }
}

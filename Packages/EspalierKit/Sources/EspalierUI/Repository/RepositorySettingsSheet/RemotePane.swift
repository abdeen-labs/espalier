// Repository Settings' Remote pane: the primary remote's URL, and for a
// GitHub repository, its account: the accounts signed in to its server, None,
// and the one it has when that isn't signed in (listed, not to choose
// again); or, without a remote, Publish.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// The account the Remote pane shows, for a GitHub repository.
struct RemotePaneAccount {
    /// The accounts signed in to the repository's server.
    let accounts: [Account]
    /// The repository's account, when it isn't signed in.
    let signedOutLogin: String?
    /// The login chosen (nil: none).
    @Binding var login: String?
}

/// The Remote pane.
struct RemotePane: View {
    let remote: Remote?
    @Binding var url: String
    var account: RemotePaneAccount?
    var publish: () -> Void = {}

    var body: some View {
        if let remote {
            Form {
                // The labels in the form's column; the fields are capsules.
                LabeledContent("Primary Remote Repository (\(remote.name)) URL") {
                    TextField("Primary Remote Repository (\(remote.name)) URL", text: $url, prompt: Text("Remote URL").fieldPrompt())
                        .labelsHidden()
                        .autocorrectionDisabled(true)
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
        } else {
            SheetCallToAction(systemImage: "icloud.and.arrow.up", message: "Publish your repository to GitHub.") {
                Button("Publish", action: publish)
                    .buttonStyle(.quiet)
            }
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

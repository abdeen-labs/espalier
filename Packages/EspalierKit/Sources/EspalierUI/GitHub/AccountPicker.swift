// The account pop-up of Clone, Publish, and the question about a
// repository's account: a capsule pop-up of the accounts, each as @login
// with the name under it, under one heading per host (GitHub.com's first,
// then each GitHub Enterprise host's, alphabetically) when they span hosts.
// "Choose an Account…" shows until one is chosen. The accounts on one host
// tell themselves apart by login.

import EspalierCore
import GitHubKit
import SwiftUI

/// A capsule pop-up of accounts.
struct AccountPicker: View {
    let accounts: [Account]
    @Binding var selection: AccountIdentity?
    /// Whether the accounts are listed under their hosts, and the title
    /// names the host: for pickers that span hosts.
    var groupsByHost = true

    var body: some View {
        CapsulePopUp("Account", selection: $selection, title: title, fitting: accounts.map(Self.title(groupsByHost: groupsByHost))) {
            if groupsByHost {
                for group in groupAccountsForPicker(accounts) {
                    MenuSection(group.title) {
                        for account in group.accounts {
                            choice(account)
                        }
                    }
                }
            } else {
                for account in accounts {
                    choice(account)
                }
            }
        }
    }

    private func choice(_ account: Account) -> MenuChoice {
        MenuChoice("@\(account.login)", value: Optional(account.identity), subtitle: Self.subtitle(account))
    }

    /// The chosen account's title, or "Choose an Account…".
    private var title: String {
        guard let selection, let account = accounts.first(where: { $0.identity == selection }) else {
            return "Choose an Account…"
        }
        return Self.title(groupsByHost: groupsByHost)(account)
    }

    /// The capsule's title for `account`: @login, and the host when the
    /// picker spans hosts.
    static func title(groupsByHost: Bool) -> (Account) -> String {
        { account in groupsByHost ? "@\(account.login) \u{2013} \(account.friendlyEndpoint)" : "@\(account.login)" }
    }

    /// The name under the login, when it isn't the login.
    static func subtitle(_ account: Account) -> String? {
        account.name.isEmpty || account.name == account.login ? nil : account.name
    }
}

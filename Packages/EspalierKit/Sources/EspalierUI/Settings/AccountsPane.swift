// Settings ▸ Accounts: GitHub.com's accounts, then GitHub Enterprise's,
// grouped under one heading per host (alphabetically; the accounts in the
// order they were signed in to). Each row shows the account's avatar, its
// name, and @login, with Sign Out. Add GitHub.com Account… and Add GitHub
// Enterprise Account… sign in to another account; without one, a call to sign
// in. Accounts signed out because their tokens stopped working offer Sign In
// Again (to that account) and Remove (they're kept for signing in again until
// the user removes them). An account whose token the keychain won't give says
// so, with Sign Out and Try Again. Sign Out asks first when repositories are
// assigned to the account, whether to keep or clear their assignments
// (`signOutAccount`), and leaves a note with a link to the page where the user
// can revoke Espalier's access (signing out can't: it needs a client secret).
// Signing in opens its sheet on the Settings window, through the window's
// GitHub actions.

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// One account, as a row shows it.
nonisolated struct AccountRowContent: Sendable, Equatable, Identifiable {
    var endpoint: String
    var login: String
    var name: String
    var avatar: AvatarUser

    var id: String {
        getAccountKey(endpoint, login)
    }

    var identity: AccountIdentity {
        AccountIdentity(endpoint: endpoint, login: login)
    }

    init(endpoint: String, login: String, name: String, avatar: AvatarUser) {
        self.endpoint = endpoint
        self.login = login
        self.name = name
        self.avatar = avatar
    }

    init(_ account: Account) {
        self.init(
            endpoint: account.endpoint,
            login: account.login,
            name: account.name,
            avatar: AvatarUser(
                email: lookupPreferredEmail(account),
                avatarURL: account.avatarURL.isEmpty ? nil : account.avatarURL,
                name: account.name,
                endpoint: account.endpoint
            )
        )
    }

    /// The row's title: the name, else @login.
    var title: String {
        name.isEmpty ? "@\(login)" : name
    }

    /// @login, under the name.
    var subtitle: String? {
        name.isEmpty ? nil : "@\(login)"
    }
}

/// The note Sign Out leaves: where to revoke Espalier's access.
nonisolated struct SignedOutNote: Sendable, Equatable, Identifiable {
    var endpoint: String
    /// The application settings page, if the account's OAuth app is known.
    var url: URL?

    var id: String {
        endpoint
    }
}

/// The accounts of one server: signed in, with tokens the keychain won't
/// give, and signed out because their tokens stopped working.
nonisolated struct AccountsHostContent: Sendable, Equatable, Identifiable {
    /// The host, as the heading shows it: `ghe.example.com`.
    var host: String
    var accounts: [AccountRowContent]
    var unreadable: [AccountRowContent]
    var invalidated: [AccountRowContent]

    init(host: String, accounts: [AccountRowContent] = [], unreadable: [AccountRowContent] = [], invalidated: [AccountRowContent] = []) {
        self.host = host
        self.accounts = accounts
        self.unreadable = unreadable
        self.invalidated = invalidated
    }

    var id: String {
        host
    }

    var isEmpty: Bool {
        accounts.isEmpty && unreadable.isEmpty && invalidated.isEmpty
    }
}

/// What the Accounts pane shows.
nonisolated struct AccountsContent: Sendable, Equatable {
    /// GitHub.com's accounts.
    var dotCom: AccountsHostContent
    /// Each GitHub Enterprise host's accounts, by host.
    var enterprise: [AccountsHostContent]
    var notes: [SignedOutNote]

    init(dotCom: AccountsHostContent = AccountsHostContent(host: "github.com"), enterprise: [AccountsHostContent] = [], notes: [SignedOutNote] = []) {
        self.dotCom = dotCom
        self.enterprise = enterprise
        self.notes = notes
    }

    @MainActor
    init(accounts: AccountsModel, notes: [SignedOutNote]) {
        let signedIn = accounts.accounts
        let unreadable = accounts.unreadableAccounts
        let saved = signedIn + unreadable
        let invalidated = accounts.invalidatedAccounts.filter { invalid in
            !saved.contains { $0.identity == invalid.identity }
        }
        func content(_ host: String, _ hostAccounts: [Account]) -> AccountsHostContent {
            let identities = Set(hostAccounts.map(\.identity))
            return AccountsHostContent(
                host: host,
                accounts: signedIn.filter { identities.contains($0.identity) }.map(AccountRowContent.init),
                unreadable: unreadable.filter { identities.contains($0.identity) }.map(AccountRowContent.init),
                invalidated: invalidated.filter { identities.contains($0.identity) }.map(AccountRowContent.init)
            )
        }
        let everyone = signedIn + unreadable + invalidated
        self.init(
            dotCom: content("github.com", everyone.filter(isDotComAccount)),
            enterprise: groupAccountsByHost(everyone.filter(isEnterpriseAccount)).map { content($0.host, $0.accounts) },
            notes: notes.filter { note in !saved.contains { $0.endpoint == note.endpoint } }
        )
    }

    /// The note for an endpoint, if an account was signed out of it here.
    func note(for endpoint: String) -> SignedOutNote? {
        notes.first { $0.endpoint == endpoint }
    }

    /// Notes for Enterprise accounts that are gone.
    var enterpriseNotes: [SignedOutNote] {
        notes.filter { !isDotCom($0.endpoint) }
    }

    /// Whether GitHub Enterprise shows its call to sign in: no account,
    /// signed in, unreadable, or signed out.
    var showsEnterpriseCallToAction: Bool {
        enterprise.allSatisfy(\.isEmpty)
    }
}

/// What the pane's buttons do.
struct AccountsActions {
    /// Signs in: to an endpoint (nil for GitHub.com,
    /// `SignInRequest.enterpriseEndpoint` for a new Enterprise account), and
    /// to one login on it (an account signed out), if any.
    var signIn: (_ endpoint: String?, _ login: String?) -> Void
    var signOut: (AccountIdentity) -> Void
    /// Reads the tokens the keychain wouldn't give again.
    var tryAgain: () -> Void
    /// Forgets a signed-out account.
    var remove: (AccountIdentity) -> Void
    var open: (URL) -> Void
}

/// Settings ▸ Accounts.
public struct AccountsPane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?
    @State private var notes: [SignedOutNote] = []

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let accounts = model?.accounts {
            AccountsForm(content: AccountsContent(accounts: accounts, notes: notes), actions: actions(accounts))
        } else {
            SettingsPanePlaceholder(tab: .accounts)
        }
    }

    private func actions(_ accounts: AccountsModel) -> AccountsActions {
        AccountsActions(
            signIn: { endpoint, login in
                guard let context else {
                    return
                }
                if let endpoint, let login {
                    GitHubActions.presentSignIn(SignInRequest(endpoint: endpoint, login: login), then: nil, in: context)
                } else {
                    context.actions.perform(.signIn(endpoint: endpoint, then: nil))
                }
            },
            signOut: { identity in
                let saved = accounts.accounts + accounts.unreadableAccounts
                guard let context, let account = saved.first(where: { $0.identity == identity }) else {
                    return
                }
                Task {
                    if let note = await Self.signOut(account, accounts: accounts, presenter: context.presenter) {
                        notes.removeAll { $0.endpoint == note.endpoint }
                        notes.append(note)
                    }
                }
            },
            tryAgain: {
                Task {
                    await accounts.retryUnreadableAccounts()
                }
            },
            remove: { identity in
                Self.removeSignedOutAccount(identity, accounts: accounts)
            },
            open: { url in
                model?.integrations.openInBrowser(url)
            }
        )
    }

    /// Forgets the signed-out account (its token is gone already). The
    /// repositories assigned to it keep their assignments.
    static func removeSignedOutAccount(_ identity: AccountIdentity, accounts: AccountsModel) {
        for account in accounts.invalidatedAccounts where account.identity == identity {
            accounts.dismissInvalidatedAccount(account)
        }
    }

    /// Signs `account` out through the window's presenter, which asks about
    /// the repositories assigned to it and shows a failure; returns the note
    /// to leave in its place when it's signed out.
    static func signOut(_ account: Account, accounts: AccountsModel, presenter: WindowPresenter) async -> SignedOutNote? {
        let note = SignedOutNote(endpoint: account.endpoint, url: GitHubWebURLs.applicationSettings(for: account))
        let signedOut: Void? = await presenter.perform { answers throws(OperationError) in
            try await accounts.signOut(account, confirmed: answers.confirmed, clearingAssignments: answers.clearAccountAssignments)
        }
        return signedOut == nil ? nil : note
    }
}

/// The Accounts pane: GitHub.com's accounts, then GitHub Enterprise's by
/// host.
struct AccountsForm: View {
    let content: AccountsContent
    let actions: AccountsActions

    var body: some View {
        SettingsPage {
            SettingsSection("GitHub.com") {
                HostAccountRows(content: content.dotCom, actions: actions)
                if let note = content.note(for: getDotComAPIEndpoint()) {
                    SignedOutNoteView(note: note, open: actions.open)
                }
                if content.dotCom.isEmpty {
                    SignInCallToAction(
                        text: "Sign in to your GitHub.com account to access your repositories.",
                        button: "Sign In…"
                    ) {
                        actions.signIn(nil, nil)
                    }
                } else {
                    SettingsButtonRow {
                        Button("Add GitHub.com Account…") {
                            actions.signIn(nil, nil)
                        }
                        .settingsButton()
                    }
                }
            }

            SettingsSection("GitHub Enterprise") {
                ForEach(content.enterprise) { host in
                    HostHeading(host: host.host)
                    HostAccountRows(content: host, actions: actions)
                }
                ForEach(content.enterpriseNotes) { note in
                    SignedOutNoteView(note: note, open: actions.open)
                }
                if content.showsEnterpriseCallToAction {
                    SignInCallToAction(
                        text: "Sign in to your GitHub Enterprise account to access your repositories.",
                        button: "Sign In…"
                    ) {
                        actions.signIn(SignInRequest.enterpriseEndpoint, nil)
                    }
                } else {
                    SettingsButtonRow {
                        Button("Add GitHub Enterprise Account…") {
                            actions.signIn(SignInRequest.enterpriseEndpoint, nil)
                        }
                        .settingsButton()
                    }
                }
            }
        }
    }
}

/// A host's heading in GitHub Enterprise: `ghe.example.com`.
private struct HostHeading: View {
    let host: String

    var body: some View {
        Text(host)
            .font(Typography.rowTitle)
            .foregroundStyle(.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Metrics.insetSmall)
            .padding(.bottom, Metrics.grid)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A host's accounts: signed in, unreadable, then signed out.
private struct HostAccountRows: View {
    let content: AccountsHostContent
    let actions: AccountsActions

    var body: some View {
        ForEach(content.accounts) { account in
            AccountRow(account: account) {
                Button("Sign Out") {
                    actions.signOut(account.identity)
                }
                .settingsButton()
            }
        }
        ForEach(content.unreadable) { account in
            UnreadableAccountRow(account: account, actions: actions)
        }
        ForEach(content.invalidated) { account in
            InvalidatedAccountRow(account: account) {
                actions.signIn(account.endpoint, account.login)
            } remove: {
                actions.remove(account.identity)
            }
        }
    }
}

/// A signed-in account: its avatar, names, and buttons; a message under
/// them when there is one.
private struct AccountRow<Trailing: View, Footer: View>: View {
    let account: AccountRowContent
    let trailing: Trailing
    let footer: Footer

    init(account: AccountRowContent, @ViewBuilder trailing: () -> Trailing, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.account = account
        self.trailing = trailing()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.SettingsWindow.messageSpacing) {
            HStack(spacing: Metrics.insetMedium) {
                Avatar(account.avatar, size: Metrics.SettingsWindow.avatarSize)
                SettingsRowText(title: account.title, description: account.subtitle)
                    .accessibilityElement(children: .combine)
                HStack(spacing: Metrics.insetSmall) {
                    trailing
                }
            }
            footer
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
    }
}

/// An account signed out because its token stopped working.
private struct InvalidatedAccountRow: View {
    let account: AccountRowContent
    let signInAgain: () -> Void
    let remove: () -> Void

    var body: some View {
        AccountRow(account: account) {
            Button("Remove", action: remove)
                .settingsButton()
            Button("Sign In Again…", action: signInAgain)
                .settingsButton()
        } footer: {
            FieldMessage("Your account token is no longer valid, so you were signed out.", kind: .warning)
        }
    }
}

/// An account whose token the keychain won't give (it's locked, or access
/// was denied): saved, but not used until Try Again reads the token.
private struct UnreadableAccountRow: View {
    let account: AccountRowContent
    let actions: AccountsActions

    var body: some View {
        AccountRow(account: account) {
            Button("Sign Out") {
                actions.signOut(account.identity)
            }
            .settingsButton()
            Button("Try Again", action: actions.tryAgain)
                .settingsButton()
        } footer: {
            FieldMessage(
                "Couldn't read this account's token from your keychain. Make sure your login keychain is unlocked, then try again.",
                kind: .warning
            )
        }
    }
}

/// Text and a sign-in button, for a server without an account.
private struct SignInCallToAction: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        SettingsRow("Not signed in", description: text) {
            Button(button, action: action)
                .settingsButton()
        }
    }
}

/// "To revoke Espalier's access, open your GitHub application settings."
private struct SignedOutNoteView: View {
    let note: SignedOutNote
    let open: (URL) -> Void

    var body: some View {
        SettingsMessageRow {
            Label {
                LinkedText(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        open(url)
                        return .handled
                    })
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.text2)
                    .accessibilityHidden(true)
            }
            .font(Typography.secondary)
            .foregroundStyle(.text2)
        }
    }

    /// The note, its last words a link to the page when it's known.
    private var text: AttributedString {
        var text = AttributedString("To revoke Espalier's access, open your ")
        var link = AttributedString("GitHub application settings")
        link.link = note.url
        text.append(link)
        text.append(AttributedString("."))
        return text
    }
}

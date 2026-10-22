// Settings ▸ Accounts: GitHub.com's account (avatar, name, @login) with Sign
// Out, or "Sign in to your GitHub.com account to access your repositories."
// with Sign In…; GitHub Enterprise's accounts ("@login (name)" and the
// server) with Sign Out and Add GitHub Enterprise Account…, or a call to
// sign in. Accounts signed out because their tokens stopped working offer
// Sign In Again and Remove (they're kept for signing in again until the user
// removes them). An account whose token the keychain won't give says so,
// with Sign Out and Try Again. Sign Out asks nothing, and leaves a note with a link to the
// page where the user can revoke Espalier's access (signing out can't: it
// needs a client secret). Signing in opens its sheet on the Settings window,
// through the window's GitHub actions.

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
    /// The server, for Enterprise accounts: `https://ghe.example.com`.
    var server: String?

    var id: String {
        endpoint
    }

    init(endpoint: String, login: String, name: String, avatar: AvatarUser, server: String?) {
        self.endpoint = endpoint
        self.login = login
        self.name = name
        self.avatar = avatar
        self.server = server
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
            ),
            server: isDotComAccount(account) ? nil : getHTMLURL(account.endpoint)
        )
    }

    /// The row's title: GitHub.com's shows the name, then @login; an
    /// Enterprise account "@login (name)", then the server.
    var title: String {
        guard server != nil else {
            return name.isEmpty ? "@\(login)" : name
        }
        return name.isEmpty || name == login ? "@\(login)" : "@\(login) (\(name))"
    }

    var subtitle: String {
        server ?? "@\(login)"
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

/// What the Accounts pane shows.
nonisolated struct AccountsContent: Sendable, Equatable {
    var dotCom: AccountRowContent?
    /// GitHub.com's account, whose token the keychain won't give.
    var unreadableDotCom: AccountRowContent?
    /// GitHub.com's account, signed out because its token stopped working.
    var invalidatedDotCom: AccountRowContent?
    var enterprise: [AccountRowContent]
    var unreadableEnterprise: [AccountRowContent]
    var invalidatedEnterprise: [AccountRowContent]
    var notes: [SignedOutNote]

    init(
        dotCom: AccountRowContent? = nil,
        unreadableDotCom: AccountRowContent? = nil,
        invalidatedDotCom: AccountRowContent? = nil,
        enterprise: [AccountRowContent] = [],
        unreadableEnterprise: [AccountRowContent] = [],
        invalidatedEnterprise: [AccountRowContent] = [],
        notes: [SignedOutNote] = []
    ) {
        self.dotCom = dotCom
        self.unreadableDotCom = unreadableDotCom
        self.invalidatedDotCom = invalidatedDotCom
        self.enterprise = enterprise
        self.unreadableEnterprise = unreadableEnterprise
        self.invalidatedEnterprise = invalidatedEnterprise
        self.notes = notes
    }

    @MainActor
    init(accounts: AccountsModel, notes: [SignedOutNote]) {
        let signedIn = accounts.accounts
        let unreadable = accounts.unreadableAccounts
        let saved = signedIn + unreadable
        let invalidated = accounts.invalidatedAccounts.filter { invalid in
            !saved.contains { $0.endpoint == invalid.endpoint }
        }
        self.init(
            dotCom: signedIn.first(where: isDotComAccount).map(AccountRowContent.init),
            unreadableDotCom: unreadable.first(where: isDotComAccount).map(AccountRowContent.init),
            invalidatedDotCom: invalidated.first(where: isDotComAccount).map(AccountRowContent.init),
            enterprise: signedIn.filter(isEnterpriseAccount).map(AccountRowContent.init),
            unreadableEnterprise: unreadable.filter(isEnterpriseAccount).map(AccountRowContent.init),
            invalidatedEnterprise: invalidated.filter(isEnterpriseAccount).map(AccountRowContent.init),
            notes: notes.filter { note in !saved.contains { $0.endpoint == note.endpoint } }
        )
    }

    /// The note for an endpoint, if its account was signed out here.
    func note(for endpoint: String) -> SignedOutNote? {
        notes.first { $0.endpoint == endpoint }
    }

    /// Whether GitHub Enterprise shows its call to sign in: no account,
    /// signed in, unreadable, or signed out.
    var showsEnterpriseCallToAction: Bool {
        enterprise.isEmpty && unreadableEnterprise.isEmpty && invalidatedEnterprise.isEmpty
    }

    /// Notes for Enterprise accounts that are gone.
    var enterpriseNotes: [SignedOutNote] {
        notes.filter { !isDotCom($0.endpoint) }
    }
}

/// What the pane's buttons do.
struct AccountsActions {
    /// Signs in to an endpoint: nil for GitHub.com,
    /// `SignInRequest.enterpriseEndpoint` for a new Enterprise account.
    var signIn: (String?) -> Void
    var signOut: (String) -> Void
    /// Reads the tokens the keychain wouldn't give again.
    var tryAgain: () -> Void
    /// Forgets a signed-out account (by endpoint).
    var remove: (String) -> Void
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
            signIn: { endpoint in
                context?.actions.perform(.signIn(endpoint: endpoint, then: nil))
            },
            signOut: { endpoint in
                let saved = accounts.accounts + accounts.unreadableAccounts
                guard let context, let account = saved.first(where: { $0.endpoint == endpoint }) else {
                    return
                }
                Task {
                    if let note = await Self.signOut(account, accounts: accounts, presenter: context.presenter) {
                        notes.removeAll { $0.endpoint == endpoint }
                        notes.append(note)
                    }
                }
            },
            tryAgain: {
                Task {
                    await accounts.retryUnreadableAccounts()
                }
            },
            remove: { endpoint in
                Self.removeSignedOutAccount(endpoint, accounts: accounts)
            },
            open: { url in
                model?.integrations.openInBrowser(url)
            }
        )
    }

    /// Forgets the signed-out account of `endpoint` (its token is gone
    /// already); the server's call to sign in shows again.
    static func removeSignedOutAccount(_ endpoint: String, accounts: AccountsModel) {
        for account in accounts.invalidatedAccounts where account.endpoint == endpoint {
            accounts.dismissInvalidatedAccount(account)
        }
    }

    /// Signs `account` out through the window's presenter, which shows a
    /// failure; returns the note to leave in its place when it's signed
    /// out.
    static func signOut(_ account: Account, accounts: AccountsModel, presenter: WindowPresenter) async -> SignedOutNote? {
        let note = SignedOutNote(endpoint: account.endpoint, url: GitHubWebURLs.applicationSettings(for: account))
        let signedOut: Void? = await presenter.perform { _ throws(OperationError) in
            try await accounts.signOut(account)
        }
        return signedOut == nil ? nil : note
    }
}

/// The Accounts pane: GitHub.com's account, then GitHub Enterprise's.
struct AccountsForm: View {
    let content: AccountsContent
    let actions: AccountsActions

    var body: some View {
        SettingsPage {
            SettingsSection("GitHub.com") {
                if let account = content.dotCom {
                    AccountRow(account: account) {
                        Button("Sign Out") {
                            actions.signOut(account.endpoint)
                        }
                        .settingsButton()
                    }
                } else if let account = content.unreadableDotCom {
                    UnreadableAccountRow(account: account, actions: actions)
                } else if let account = content.invalidatedDotCom {
                    InvalidatedAccountRow(account: account) {
                        actions.signIn(account.endpoint)
                    } remove: {
                        actions.remove(account.endpoint)
                    }
                } else {
                    SignInCallToAction(
                        text: "Sign in to your GitHub.com account to access your repositories.",
                        button: "Sign In…"
                    ) {
                        actions.signIn(nil)
                    }
                }
                if let note = content.note(for: getDotComAPIEndpoint()) {
                    SignedOutNoteView(note: note, open: actions.open)
                }
            }

            SettingsSection("GitHub Enterprise") {
                ForEach(content.enterprise) { account in
                    AccountRow(account: account) {
                        Button("Sign Out") {
                            actions.signOut(account.endpoint)
                        }
                        .settingsButton()
                    }
                }
                ForEach(content.unreadableEnterprise) { account in
                    UnreadableAccountRow(account: account, actions: actions)
                }
                ForEach(content.invalidatedEnterprise) { account in
                    InvalidatedAccountRow(account: account) {
                        actions.signIn(account.endpoint)
                    } remove: {
                        actions.remove(account.endpoint)
                    }
                }
                ForEach(content.enterpriseNotes) { note in
                    SignedOutNoteView(note: note, open: actions.open)
                }
                if content.showsEnterpriseCallToAction {
                    SignInCallToAction(
                        text: "Sign in to your GitHub Enterprise account to access your repositories.",
                        button: "Sign In…"
                    ) {
                        actions.signIn(SignInRequest.enterpriseEndpoint)
                    }
                } else {
                    SettingsButtonRow {
                        Button("Add GitHub Enterprise Account…") {
                            actions.signIn(SignInRequest.enterpriseEndpoint)
                        }
                        .settingsButton()
                    }
                }
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
                actions.signOut(account.endpoint)
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

// Ported from desktop/app/src/ui/repository-account/repository-account-dialog.tsx
//
// The question about a repository's account (`Prompt.repositoryAccount`):
// which signed-in account on its server to use (all of them, or those that
// can see the repository), with Sign In to Another Account…, whose new
// account is chosen; or, for a repository whose account is signed out,
// Sign In… to that account again, or Choose Another Account. Without an
// account on the server it's the sign-in sheet for the server. The account
// is only answered here; the state layer assigns it.

import EspalierCore
import EspalierSupport
import GitHubKit
import SwiftUI

/// What the question shows.
nonisolated struct RepositoryAccountContent: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// The repository's account, signed out: sign in to it again, or
        /// choose another.
        case signInAgain(login: String)
        /// Choose among `accounts`.
        case choose
        /// No account on the server: sign in to it.
        case signIn
    }

    var repositoryName: String
    /// The server's host: `github.com`.
    var host: String
    var endpoint: String
    var step: Step
    /// The accounts to choose among.
    var accounts: [Account]

    /// The content for `request`, with the signed-in `accounts`.
    init(request: RepositoryAccountRequest, accounts: [Account], choosingAnother: Bool = false) {
        repositoryName = request.repositoryName
        host = request.host
        endpoint = request.endpoint
        let onServer = accounts.filter { JSCompat.strictEquals($0.endpoint, request.endpoint) }
        if let candidates = request.candidates {
            self.accounts = candidates.compactMap { identity in onServer.first { $0.identity == identity } }
        } else {
            self.accounts = onServer
        }
        if let login = request.signedOutLogin, !choosingAnother,
           !onServer.contains(where: { $0.identity == AccountIdentity(endpoint: request.endpoint, login: login) }) {
            step = .signInAgain(login: login)
        } else if self.accounts.isEmpty, request.candidates == nil {
            step = .signIn
        } else {
            step = .choose
        }
    }

    /// The question.
    var message: String {
        switch step {
        case .signInAgain(let login):
            "\(repositoryName) uses @\(login) on \(host), which isn't signed in. Sign in to keep using this account."
        case .choose, .signIn:
            "Choose the account Espalier uses for \(repositoryName) on \(host): for GitHub's API and for HTTPS Git. Your commits' author doesn't change."
        }
    }
}

/// What the question's buttons do.
struct RepositoryAccountActions {
    var cancel: () -> Void
    /// Answers with the account chosen.
    var use: (AccountIdentity) -> Void
    /// Signs in to the server, to the login given (the repository's own)
    /// or any.
    var signIn: (_ login: String?) -> Void
    /// Shows the accounts to choose among instead of signing in again.
    var chooseAnother: () -> Void
}

/// The question's form.
struct RepositoryAccountForm: View {
    let content: RepositoryAccountContent
    @Binding var selection: AccountIdentity?
    let actions: RepositoryAccountActions

    var body: some View {
        SheetScaffold("Choose an Account", message: content.message) {
            if case .choose = content.step {
                VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                    AccountPicker(accounts: content.accounts, selection: $selection, groupsByHost: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Sign In to Another Account…") {
                        actions.signIn(nil)
                    }
                    .buttonStyle(.textLink)
                }
            }
        } buttons: {
            switch content.step {
            case .signInAgain(let login):
                Button("Choose Another Account", action: actions.chooseAnother)
                    .buttonStyle(.quiet)
                SheetButtons("Sign In…", cancel: actions.cancel) {
                    actions.signIn(login)
                }
            case .choose, .signIn:
                SheetButtons("Use Account", isConfirmDisabled: selection == nil, cancel: actions.cancel) {
                    if let selection {
                        actions.use(selection)
                    }
                }
            }
        }
    }
}

/// The question, as the prompt host shows it.
struct RepositoryAccountPrompt: View {
    let request: RepositoryAccountRequest
    let onAnswer: (AccountIdentity?) -> Void
    @Environment(WindowContext.self) private var context
    @State private var selection: AccountIdentity?
    @State private var choosingAnother = false
    /// Accounts signed in from the question, before the app's list has
    /// them.
    @State private var signedIn: [Account] = []

    var body: some View {
        let content = RepositoryAccountContent(request: request, accounts: accounts, choosingAnother: choosingAnother)
        if case .signIn = content.step {
            // Nothing to choose from: the server's sign-in.
            SignInSheet(request: SignInRequest(endpoint: request.endpoint)) { account in
                onAnswer(account.flatMap { JSCompat.strictEquals($0.endpoint, request.endpoint) ? $0.identity : nil })
            }
        } else {
            RepositoryAccountForm(content: content, selection: $selection, actions: RepositoryAccountActions(
                cancel: { onAnswer(nil) },
                use: { onAnswer($0) },
                signIn: signIn,
                chooseAnother: { choosingAnother = true }
            ))
        }
    }

    /// The signed-in accounts, those signed in from here included.
    private var accounts: [Account] {
        let accounts = context.app.accounts.accounts
        return accounts + signedIn.filter { account in !accounts.contains { $0.identity == account.identity } }
    }

    /// Signs in to the server on top of the question: the repository's own
    /// account answers at once; another is chosen.
    private func signIn(_ login: String?) {
        let endpoint = request.endpoint
        context.modals.presentSheet(id: SignInSheet.sheetID) {
            SignInSheet(request: SignInRequest(endpoint: endpoint, login: login)) { account in
                guard let account, JSCompat.strictEquals(account.endpoint, endpoint) else {
                    return
                }
                if login != nil {
                    onAnswer(account.identity)
                    return
                }
                signedIn.append(account)
                selection = account.identity
            }
        }
    }
}

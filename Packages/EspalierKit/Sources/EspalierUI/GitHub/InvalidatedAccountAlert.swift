// The alert for an account signed out because GitHub rejected its token, or
// the token expired or is missing: "Signed Out" [Not Now] [Sign In…], naming
// the account. Sign In… opens the sign-in sheet to sign in again to that
// account, other accounts on the server staying signed in, with what
// Espalier knows of the server filled in.
// Problems reading or storing the accounts show as alerts too. Both show on
// the main window, once each.

import EspalierCore
import GitHubKit
import SwiftUI

/// The invalidated-token alert, and the accounts' problems.
@MainActor
enum InvalidatedAccountAlert {
    /// The alert for `account`.
    nonisolated static func content(for account: Account) -> AlertContent {
        AlertContent(
            title: "Signed Out",
            message: "The token for @\(account.login) on \(account.friendlyEndpoint) is no longer valid, so you've been signed out of it. Sign in again?",
            buttons: [AlertContent.Button("Sign In…", role: .primary), AlertContent.Button("Not Now", role: .cancel)]
        )
    }

    /// The alert for a problem with the stored accounts.
    nonisolated static func content(for issue: AccountsIssue) -> AlertContent {
        AlertContent(title: "Error", message: issue.message, buttons: [AlertContent.Button("Close", role: .primary)])
    }

    /// Shows the alert for each account newly signed out, once; an account
    /// signed in and signed out again alerts again.
    static func presentInvalidatedAccounts(in context: WindowContext) {
        let state = context.state.featureState(GitHubWindowState.self) { GitHubWindowState() }
        for account in state.accountsToAlert(context.app.accounts.invalidatedAccounts) {
            Task {
                let response = await context.modals.alert(content(for: account))
                if response.buttonIndex == 0 {
                    GitHubActions.presentSignIn(SignInRequest(endpoint: account.endpoint, login: account.login), then: nil, in: context)
                }
            }
        }
    }

    /// Shows each problem with the stored accounts, once, then forgets it.
    static func presentIssues(in context: WindowContext) {
        let state = context.state.featureState(GitHubWindowState.self) { GitHubWindowState() }
        let accounts = context.app.accounts
        for issue in state.issuesToShow(accounts.issues) {
            Task {
                _ = await context.modals.alert(content(for: issue))
                accounts.dismissIssue(issue.id)
            }
        }
    }
}

/// GitHub's per-window state.
@MainActor
final class GitHubWindowState {
    /// The invalidated accounts that have been alerted.
    var alertedInvalidatedAccounts: Set<AccountIdentity> = []
    /// The account problems shown.
    var shownIssues: Set<AccountsIssue.ID> = []

    /// The invalidated accounts not alerted yet. An account signed in again
    /// is forgotten, so it alerts again if it's signed out again.
    func accountsToAlert(_ invalidated: [Account]) -> [Account] {
        alertedInvalidatedAccounts.formIntersection(invalidated.map(\.identity))
        return invalidated.filter { alertedInvalidatedAccounts.insert($0.identity).inserted }
    }

    /// The problems not shown yet.
    func issuesToShow(_ issues: [AccountsIssue]) -> [AccountsIssue] {
        issues.filter { shownIssues.insert($0.id).inserted }
    }
}

/// The main window's GitHub presentation: invalidated accounts, account
/// problems, and the notifications clicked (attached by the shell's
/// presentation hosts, for the main window only).
struct GitHubPresentationHosts: ViewModifier {
    let context: WindowContext

    func body(content: Content) -> some View {
        content
            .onChange(of: context.app.accounts.invalidatedAccounts.map(\.identity), initial: true) {
                InvalidatedAccountAlert.presentInvalidatedAccounts(in: context)
            }
            .onChange(of: context.app.accounts.issues.map(\.id), initial: true) {
                InvalidatedAccountAlert.presentIssues(in: context)
            }
            .onAppear {
                NotificationRouter.shared.attach(context)
            }
    }
}

extension View {
    /// Attaches the main window's GitHub presentation.
    func gitHubPresentationHosts(_ context: WindowContext) -> some View {
        modifier(GitHubPresentationHosts(context: context))
    }
}

// Ported from desktop's multi-account stack (#23020-#23044): a repository's
// assigned account, choosing it, and clearing it.
//
// A repository's account is its GitHub repository's endpoint and its
// `accountLogin`. It's assigned once to repositories saved before accounts
// were (RepositoryListDocument.swift), when a repository is added or cloned
// (the only account that can see it, or the one the user picks), when one is
// published, and when the user picks one: in Repository Settings, the
// repository list's Account menu, or when asked. Signing in never assigns
// one; signing out clears assignments only when the user says to.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "repository-accounts")

extension AppModel {
    // MARK: Assigning

    /// Assigns `login` (nil: none) to a repository, moving it to that
    /// account's row of its GitHub repository. A repository without a GitHub
    /// repository has no account.
    func assignAccount(_ login: String?, to id: RepositoryID) {
        guard let record = record(id) else {
            return
        }
        guard let gitHubRepository = record.gitHubRepository else {
            if record.accountLogin != nil {
                updateRecord(id) { $0.accountLogin = nil }
            }
            return
        }
        setGitHubRepository(gitHubRepository, for: id, accountLogin: login)
    }

    /// Assigns the repository the account `login` on its GitHub
    /// repository's endpoint (nil: none), the user's choice, and loads its
    /// GitHub data with it: what was loaded with the account it had goes.
    ///
    /// - Throws: `.precondition` when the repository isn't in the list or on
    ///   GitHub, or the account isn't signed in.
    public func updateRepositoryAccount(_ id: RepositoryID, login: String?) async throws(OperationError) {
        guard let record = record(id) else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .assignAccount, repositoryID: id)
        }
        guard let gitHubRepository = record.gitHubRepository else {
            throw OperationError(.precondition("\(record.displayName) isn't a GitHub repository."), operation: .assignAccount, repositoryID: id)
        }
        var assigned: String?
        if let login {
            guard let account = accounts.account(AccountIdentity(endpoint: gitHubRepository.endpoint, login: login)) else {
                let host = RepositoryAccountRequest(repositoryName: record.displayName, endpoint: gitHubRepository.endpoint).host
                throw OperationError(.precondition("@\(login) isn't signed in to \(host)."), operation: .assignAccount, repositoryID: id)
            }
            assigned = account.login
        }
        guard !isSameLogin(record.accountLogin, assigned) else {
            return
        }
        logger.info("Assigning \(assigned ?? "no account", privacy: .public) to a repository on \(gitHubRepository.endpoint, privacy: .public)")
        assignAccount(assigned, to: id)
        await repositoryAccountDidChange(id)
    }

    /// Clears the account of every repository assigned to `identity` (the
    /// user signed out of it and asked to): they have no account until
    /// one is chosen.
    func clearAccountAssignments(_ identity: AccountIdentity) {
        for record in repositories where record.accountIdentity == identity {
            assignAccount(nil, to: record.id)
            models[record.id]?.gitHub.accountDidChange()
        }
    }

    /// A repository was assigned another account: drops what was loaded
    /// with the one it had (pull requests, checks, protection, rules) and,
    /// for the selected repository, loads it again with the new one.
    func repositoryAccountDidChange(_ id: RepositoryID) async {
        guard let model = models[id] else {
            return
        }
        model.gitHub.accountDidChange()
        guard case .repository(id) = selection, !model.record.isMissing else {
            return
        }
        await refreshGitHubAssociation(id)
        await model.gitHub.refreshPullRequests()
    }

    /// The signed-in accounts changed (signing in or out, a new token):
    /// each repository's checks drop what an account that's gone loaded.
    func signedInAccountsDidChange() {
        for model in models.values {
            model.gitHub.signedInAccountsDidChange()
        }
    }

    // MARK: Asking for an account

    /// The account for something the user started in a repository: its
    /// assigned account when it's signed in; otherwise, the user is asked to
    /// sign in to it again or choose another (one signed out), to choose one
    /// (none assigned), or to sign in to the repository's server (no
    /// account there), and the account picked is assigned and returned.
    ///
    /// Nil when the repository isn't on GitHub, the user cancels, or the
    /// assigned account's token can't be read from the keychain. A question
    /// already asked for the repository is joined. Work that runs in the
    /// background never asks: it uses `accounts.account(for:)`.
    public func ensureRepositoryAccount(_ id: RepositoryID) async -> Account? {
        guard let record = record(id), record.gitHubRepository != nil else {
            return nil
        }
        if let account = accounts.account(for: record) {
            return account
        }
        if let identity = record.accountIdentity, accounts.unreadableAccounts.contains(where: { $0.identity == identity }) {
            return nil
        }
        let task: Task<Account?, Never>
        if let pending = repositoryAccountPrompts[id] {
            task = pending
        } else {
            task = Task { await self.askForRepositoryAccount(id) }
            repositoryAccountPrompts[id] = task
            Task {
                _ = await task.value
                if self.repositoryAccountPrompts[id] == task {
                    self.repositoryAccountPrompts[id] = nil
                }
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // The operation that asked ended (git gave up): the question
            // closes.
            task.cancel()
        }
    }

    private func askForRepositoryAccount(_ id: RepositoryID) async -> Account? {
        guard let record = record(id), let gitHubRepository = record.gitHubRepository else {
            return nil
        }
        let endpoint = gitHubRepository.endpoint
        let request = RepositoryAccountRequest(
            repositoryName: nameOf(record),
            endpoint: endpoint,
            signedOutLogin: record.accountLogin
        )
        guard let identity = await prompts.promptForRepositoryAccount(request) else {
            return nil
        }
        await accounts.reloadAccounts()
        guard let account = accounts.account(AccountIdentity(endpoint: endpoint, login: identity.login)) else {
            logger.error("The account chosen for a repository isn't signed in to \(endpoint, privacy: .public)")
            return nil
        }
        // The repository may have moved to another server meanwhile.
        guard let current = self.record(id), current.gitHubRepository?.endpoint == endpoint else {
            return nil
        }
        if !isSameLogin(current.accountLogin, account.login) {
            assignAccount(account.login, to: id)
            models[id]?.gitHub.accountDidChange()
            accounts.startTracked {
                await self.refreshGitHubAssociation(id)
            }
        }
        return account
    }

    // MARK: Choosing an account for a remote

    /// Chooses the account for a repository at `remoteURL` being added or
    /// cloned: each signed-in account on its server is checked for access,
    /// and the user picks when several might see it
    /// (`chooseAccountForRemoteRepository`).
    ///
    /// - Throws: When the account the user picked can't see the repository,
    ///   or its access can't be checked.
    func chooseAccount(forRemote remoteURL: String) async throws -> RemoteAccountChoice {
        let lookup = lookupRepositoryAccess(runtime: environment.gitHub)
        return try await chooseAccountForRemoteRepository(accounts.accounts, remoteURL, lookup: lookup) { match, candidates in
            await self.promptForRemoteAccount(match, candidates)
        }
    }

    /// Asks which of `candidates` to use for the repository `match` names;
    /// the account chosen, or signed in to from the question.
    private func promptForRemoteAccount(_ match: MatchedGitHubRepository, _ candidates: [Account]) async -> Account? {
        let request = RepositoryAccountRequest(
            repositoryName: "\(match.owner)/\(match.name)",
            endpoint: match.account.endpoint,
            candidates: candidates.map(\.identity)
        )
        guard let identity = await prompts.promptForRepositoryAccount(request) else {
            return nil
        }
        await accounts.reloadAccounts()
        return accounts.account(identity) ?? candidates.first { $0.identity == identity }
    }

    /// Associates a repository with what choosing its account found, and
    /// assigns it the account.
    func associate(_ id: RepositoryID, with assignment: RemoteRepositoryAssignment) {
        let account = assignment.account
        let gitHubRepository = assignment.apiRepository.map {
            upsertGitHubRepository(account.endpoint, $0, accountLogin: account.login)
        } ?? upsertGitHubRepositoryFromMatch(assignment.match)
        setGitHubRepository(gitHubRepository, for: id, accountLogin: account.login)
    }
}

/// Whether two logins are the same, ignoring case as GitHub does; nil is
/// the same only as nil.
public func isSameLogin(_ x: String?, _ y: String?) -> Bool {
    switch (x, y) {
    case (nil, nil): true
    case (let x?, let y?): JSCompat.caseInsensitiveEquals(x, y)
    default: false
    }
}

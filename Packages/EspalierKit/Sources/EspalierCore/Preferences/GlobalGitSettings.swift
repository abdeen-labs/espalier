import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "settings")

/// The global git configuration Settings ▸ Git shows: who commits, and the
/// default branch of new repositories.
public struct GlobalGitSettings: Sendable, Equatable {
    /// `user.name` in the global configuration; nil when unset.
    public var name: String?
    /// `user.email` in the global configuration; nil when unset.
    public var email: String?
    /// `init.defaultBranch`, or `main` when unset.
    public var defaultBranch: String

    public init(name: String?, email: String?, defaultBranch: String) {
        self.name = name
        self.email = email
        self.defaultBranch = defaultBranch
    }

    /// The settings as Settings ▸ Git first shows them: a missing or empty
    /// name or email filled in from the GitHub.com account, else the first
    /// account, with its login and its preferred email
    /// (`lookupPreferredEmail`). Nothing is written until the user saves them.
    public func fillingAuthor(from accounts: [Account]) -> GlobalGitSettings {
        var settings = self
        let hasName = !(name ?? "").isEmpty
        let hasEmail = !(email ?? "").isEmpty
        guard !hasName || !hasEmail, let account = accounts.first(where: isDotComAccount) ?? accounts.first else {
            return settings
        }
        if !hasName {
            settings.name = account.login
        }
        if !hasEmail {
            settings.email = lookupPreferredEmail(account)
        }
        return settings
    }
}

/// The author a GitHub account suggests in the welcome flow's Configure Git
/// ("Use my GitHub account name and email address"): the first account's
/// name, or its login without one, and its preferred email.
public struct GitHubAuthorInfo: Sendable, Equatable {
    public let name: String
    public let email: String

    /// The first account's author information; nil without accounts.
    public init?(accounts: [Account]) {
        guard let account = accounts.first else {
            return nil
        }
        name = account.name.isEmpty ? account.login : account.name
        email = lookupPreferredEmail(account)
    }
}

// MARK: - Account emails

/// An email address the author form offers: an account's verified address,
/// or GitHub.com's private address (`<id>+<login>@users.noreply.github.com`).
public struct GitAuthorEmailChoice: Sendable, Hashable {
    public let email: String
    /// The account it belongs to.
    public let account: Account
    /// "(GitHub.com)" or "(GitHub Enterprise)", shown after the address when
    /// the user has both kinds of account; nil otherwise.
    public let accountSuffix: String?
}

/// The email addresses the author form offers for `accounts`, without
/// duplicates (compared case-insensitively, the first kept), in account
/// order: each account's verified addresses, then, for GitHub.com, its
/// private address, always. An address that isn't one of them shows as
/// "Other", with `gitEmailAttribution(_:accounts:)`'s warning.
public func gitAuthorEmailChoices(for accounts: [Account]) -> [GitAuthorEmailChoice] {
    let showsAccountType = accounts.contains(where: isDotComAccount) && accounts.contains(where: isEnterpriseAccount)
    var seen = Set<String>()
    var choices: [GitAuthorEmailChoice] = []
    for account in accounts {
        var emails = account.emails.filter(\.verified).map(\.email)
        if isDotComAccount(account) {
            emails.append(getStealthEmailForAccount(account))
        }
        for email in emails where seen.insert(email.lowercased()).inserted {
            let suffix = showsAccountType ? (isDotComAccount(account) ? "(GitHub.com)" : "(GitHub Enterprise)") : nil
            choices.append(GitAuthorEmailChoice(email: email, account: account, accountSuffix: suffix))
        }
    }
    return choices
}

/// Whether `email` is one of the author form's choices for `accounts`,
/// ignoring case; when it isn't, the form shows "Other".
public func isGitAuthorEmailChoice(_ email: String, accounts: [Account]) -> Bool {
    let needle = email.lowercased()
    return gitAuthorEmailChoices(for: accounts).contains { $0.email.lowercased() == needle }
}

/// Whether commits made with an email address are attributed to the user's
/// account on GitHub, with the words for it.
public struct GitEmailAttribution: Sendable, Equatable {
    /// Whether one of the accounts claims the address (a verified address,
    /// or its private noreply address in either format).
    public let isAttributable: Bool
    /// "This email address matches your GitHub account." or "This email
    /// address doesn't match your GitHub account. Your commits won't be
    /// attributed to you."
    public let message: String
}

/// The attribution check the author form shows under an "Other" address;
/// nil without accounts or with a blank address.
public func gitEmailAttribution(_ email: String, accounts: [Account]) -> GitEmailAttribution? {
    guard !accounts.isEmpty, !JSCompat.trim(email).isEmpty else {
        return nil
    }

    let isAttributable = accounts.contains { isAttributableEmailFor($0, email) }
    let accountDescription: String
    if accounts.count == 1 {
        accountDescription = "your \(isDotComAccount(accounts[0]) ? "GitHub" : "GitHub Enterprise") account"
    } else {
        accountDescription = "your GitHub.com or GitHub Enterprise accounts"
    }
    let verb = isAttributable ? "matches" : "doesn't match"
    let info = isAttributable ? "" : " Your commits won't be attributed to you."
    return GitEmailAttribution(
        isAttributable: isAttributable,
        message: "This email address \(verb) \(accountDescription).\(info)"
    )
}

// MARK: - Author names

/// Whether `name` can be git's `user.name` without git refusing to commit
/// ("name consists only of disallowed characters"), by git's own rule
/// (ident.c): a name made only of what git calls crud (control
/// characters, spaces, and `.,:;<>"\'`) is invalid, while any other
/// character makes it valid, since git strips the crud around it. An empty
/// name counts as valid (the setters never write one).
public func gitAuthorNameIsValid(_ name: String) -> Bool {
    // `/^[\x00-\x20.,:;<>"\\']+$/`: every crud character is ASCII, so
    // scalars and JavaScript's code units agree.
    let crud: Set<Unicode.Scalar> = [".", ",", ":", ";", "<", ">", "\"", "\\", "'"]
    let isCrudOnly = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.value <= 0x20 || crud.contains($0) }
    return !isCrudOnly
}

/// The message for a name `gitAuthorNameIsValid` rejects.
public let invalidGitAuthorNameMessage = "The name can't be only spaces and punctuation."

// MARK: - Reading and writing

extension AppModel {
    /// The global author and default branch, as git reads them.
    ///
    /// - Throws: Git's error when the configuration can't be read.
    public func loadGlobalGitSettings() async throws(OperationError) -> GlobalGitSettings {
        do {
            return try await environment.withRuntimes {
                async let name = getGlobalConfigValue("user.name")
                async let email = getGlobalConfigValue("user.email")
                async let defaultBranch = getDefaultBranch()
                return GlobalGitSettings(name: try await name, email: try await email, defaultBranch: try await defaultBranch)
            }
        } catch {
            throw await integrations.classify(error, as: .setGlobalGitConfig)
        }
    }

    /// Sets the global author (`user.name`, `user.email`), writing only the
    /// values given that differ from what's configured; nil or empty values
    /// are left as they are (an empty name breaks committing). Then the
    /// selected repository reloads its author.
    ///
    /// Settings ▸ Git, the welcome flow's Configure Git, and the commit
    /// message's "update email" write through here.
    ///
    /// - Throws: Git's error. When another program holds the configuration's
    ///   lock file, `OperationError.gitConfigLockFilePath` names it, so the
    ///   user can delete it and try again.
    public func setGlobalGitAuthor(name: String?, email: String?) async throws(OperationError) {
        let environment = environment
        let writtenFlag = WrittenFlag()
        defer {
            if writtenFlag.value {
                selectedRepository?.requestRefresh(.metadata, reason: .user)
            }
        }
        do {
            try await integrations.globalConfigWriter.run {
                try await environment.withRuntimes {
                    for (key, value) in [("user.name", name), ("user.email", email)] {
                        guard let value, !value.isEmpty else {
                            continue
                        }
                        if let current = try await getGlobalConfigValue(key), JSCompat.strictEquals(current, value) {
                            continue
                        }
                        try await setGlobalConfigValue(key, value)
                        writtenFlag.value = true
                    }
                }
            }
        } catch {
            throw await integrations.classify(error, as: .setGlobalGitConfig)
        }
    }

    /// Sets the default branch name of new repositories
    /// (`init.defaultBranch`), as git's rules allow it
    /// (`sanitizedRefName`: Settings shows "Will be saved as <name>." when
    /// that differs from what was typed). An empty name changes nothing, and
    /// neither does the current one.
    ///
    /// - Returns: The name now configured, or nil when nothing was written.
    /// - Throws: As `setGlobalGitAuthor(name:email:)`.
    @discardableResult
    public func setDefaultBranchForNewRepositories(_ name: String) async throws(OperationError) -> String? {
        let branchName = sanitizedRefName(name)
        guard !branchName.isEmpty else {
            return nil
        }
        let environment = environment
        do {
            return try await integrations.globalConfigWriter.run {
                try await environment.withRuntimes {
                    guard !JSCompat.strictEquals(try await getDefaultBranch(), branchName) else {
                        return nil
                    }
                    try await setDefaultBranch(branchName)
                    return branchName
                }
            }
        } catch {
            throw await integrations.classify(error, as: .setGlobalGitConfig)
        }
    }

    /// Deletes the lock file that kept git from writing its configuration
    /// (`OperationError.gitConfigLockFilePath`), so the write can be tried
    /// again. A lock file that is already gone is fine.
    ///
    /// - Throws: `.precondition` for a path that isn't a lock file, and the
    ///   file system's error when it can't be deleted.
    public func removeGitConfigLockFile(_ path: String) async throws(OperationError) {
        guard POSIXPath.isAbsolute(path), JSCompat.endsWith(path, ".lock") else {
            throw OperationError(.precondition("\(path) is not a lock file."), operation: .setGlobalGitConfig)
        }
        guard unlink(path) == 0 || errno == ENOENT else {
            let code = errno
            throw OperationError(
                .fileSystem(String(cString: strerror(code))),
                operation: .setGlobalGitConfig,
                underlying: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            )
        }
    }

    /// The author form's email choices for the signed-in accounts.
    public var gitAuthorEmailChoices: [GitAuthorEmailChoice] {
        EspalierCore.gitAuthorEmailChoices(for: accounts.accounts)
    }

    /// The attribution check for `email` against the signed-in accounts.
    public func gitEmailAttribution(_ email: String) -> GitEmailAttribution? {
        EspalierCore.gitEmailAttribution(email, accounts: accounts.accounts)
    }
}

extension OperationError {
    /// The configuration lock file that kept git from writing, when that is
    /// why a global configuration write failed.
    public var gitConfigLockFilePath: String? {
        guard let gitError = underlying as? GitError, isConfigFileLockError(gitError) else {
            return nil
        }
        return parseConfigLockFilePathFromError(gitError.result)
    }

    /// The explanation for `gitConfigLockFilePath`, which asks to delete the
    /// lock file and try again.
    public var gitConfigLockFileMessage: String? {
        gitConfigLockFilePath.map { path in
            "Couldn't update your Git configuration because a lock file already exists at \(path).\n\n"
                + "Another tool may be changing the configuration, or a Git process may have quit without "
                + "removing the lock file. Delete the lock file and try again?"
        }
    }
}

// MARK: - Global Git LFS filters

extension IntegrationsModel {
    /// Installs the global Git LFS filters without overwriting other values,
    /// at launch. A failure is kept in `lfsFiltersError` for the UI to show:
    /// filters configured with other values are `.lfsAttributeMismatch`,
    /// whose recovery is `updateGlobalLFSFilters()`.
    func installGlobalLFSFiltersAtLaunch() async {
        do {
            try await installGlobalFilters(force: false)
            if lfsFiltersError != nil {
                lfsFiltersError = nil
            }
        } catch {
            let failure = await classify(error, as: .updateLFSFilters)
            logger.error("Could not install the global Git LFS filters: \(failure.message, privacy: .public)")
            lfsFiltersError = failure
        }
    }

    /// Overwrites the global Git LFS filters with Git LFS's values ("Update
    /// Existing Filters"), which clears `lfsFiltersError`.
    public func updateGlobalLFSFilters() async throws(OperationError) {
        do {
            try await installGlobalFilters(force: true)
        } catch {
            throw await classify(error, as: .updateLFSFilters)
        }
        if lfsFiltersError != nil {
            lfsFiltersError = nil
        }
    }

    /// Forgets the launch failure once the user has seen it ("Not Now").
    public func dismissLFSFiltersError() {
        lfsFiltersError = nil
    }

    private func installGlobalFilters(force: Bool) async throws {
        let environment = environment
        try await globalConfigWriter.run {
            try await environment.withRuntimes {
                try await installGlobalLFSFilters(force)
            }
        }
    }
}

// MARK: - Serializing writes

/// Runs Espalier's writes of the global git configuration one at a time,
/// in the order they were asked for, so they never collide on git's lock
/// file (Settings applies each change at once, so two can overlap).
///
/// A write runs in a task of its own: cancelling the caller never stops a
/// write halfway.
@MainActor
final class GlobalConfigWriter {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async -> Result<T, any Error> in
            await previous?.value
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        tail = Task { @MainActor in
            _ = await task.value
        }
        return try await task.value.get()
    }
}

/// Whether a write happened, set inside a write and read after it.
@MainActor
private final class WrittenFlag {
    var value = false
}

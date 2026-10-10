import Foundation
import GitHubKit
import GitKit

/// The settings pane a recovery opens.
public enum SettingsPane: String, Sendable, Hashable, CaseIterable {
    case accounts, integrations, git, appearance, notifications, prompts, advanced, ai
}

/// Something the user can do about an error.
///
/// Headless recoveries (`isHeadless`) run with `perform(in:)`. The others
/// need the UI first: it shows its flow (sign in, choose a fork, review
/// secrets, settings) and then calls the owner's intent.
public enum Recovery: Sendable {
    /// Run the operation again ("Retry Clone" for clones).
    case retry(any RetryableOperation)
    /// Stash the current branch's changes, then run the operation again
    /// ("Stash Changes and Continue"); offered only when the branch has no
    /// stash.
    case stashChangesAndRetry(RepositoryID, any RetryableOperation)
    /// Clear a rebase's state that Espalier can't continue or abort
    /// (`LeftoverRebase`), then run the operation git or Espalier refused
    /// over it again ("Clear Old Rebase and Continue").
    case clearLeftoverRebaseAndRetry(RepositoryID, any RetryableOperation)
    /// Fetch the remote's new commits ("Fetch").
    case fetch(RepositoryID)
    /// Delete the files instead of moving them to the Trash ("Permanently
    /// Discard Changes").
    case discardPermanently(RepositoryID, [WorkingDirectoryFileChange])
    /// Overwrite the global Git LFS filters ("Update Existing Filters").
    case updateLFSFilters
    /// Open the global git configuration in the editor ("Edit Global Git
    /// Config…").
    case editGlobalGitConfig
    /// Fork the repository and push there ("Fork This Repository"); the UI
    /// confirms, then calls `sync.convertToFork`.
    case createFork(RepositoryID)
    /// Sign in to the endpoint again, then run the operation again ("Continue
    /// in Browser").
    case signIn(endpoint: String, then: (any RetryableOperation)?)
    /// Review the detected secrets and bypass them ("Bypass").
    case reviewPushProtection(RepositoryID, [SecretScanResult])
    /// Open a settings pane ("Open Settings").
    case openSettings(SettingsPane)
    /// Download the suggested editor ("Download Visual Studio Code").
    case downloadSuggestedEditor
    /// Open the account's page for Espalier in the user's GitHub settings,
    /// where an organization's access can be requested ("Request Access on
    /// GitHub").
    case requestOrganizationAccess(URL)

    /// The button's title.
    public var title: String {
        switch self {
        case .retry(let operation):
            operation.recoveryTitle ?? (operation.kind == .clone ? "Retry Clone" : "Retry")
        case .stashChangesAndRetry:
            "Stash Changes and Continue"
        case .clearLeftoverRebaseAndRetry:
            "Clear Old Rebase and Continue"
        case .fetch:
            "Fetch"
        case .discardPermanently:
            "Permanently Discard Changes"
        case .updateLFSFilters:
            "Update Existing Filters"
        case .editGlobalGitConfig:
            "Edit Global Git Config…"
        case .createFork:
            "Fork This Repository…"
        case .signIn:
            "Continue in Browser"
        case .reviewPushProtection:
            "Bypass"
        case .openSettings:
            "Open Settings"
        case .downloadSuggestedEditor:
            "Download \(suggestedExternalEditor.name)"
        case .requestOrganizationAccess:
            "Request Access on GitHub"
        }
    }

    /// Whether `perform(in:)` can run it without the UI.
    public var isHeadless: Bool {
        switch self {
        case .retry, .stashChangesAndRetry, .fetch, .discardPermanently, .updateLFSFilters, .editGlobalGitConfig,
             .downloadSuggestedEditor, .requestOrganizationAccess, .clearLeftoverRebaseAndRetry:
            true
        case .createFork, .signIn, .reviewPushProtection, .openSettings:
            false
        }
    }

    /// Runs a headless recovery.
    ///
    /// - Parameter confirmed: Confirmations the user gave for what it runs
    ///   (the retried operation's, the stash's).
    /// - Returns: What the operation it ran again returned, for the window
    ///   to report as it reports the first run; `.nothing` for the others.
    /// - Throws: The `OperationError` of what it ran; a precondition error
    ///   for a recovery that needs the UI first.
    ///
    /// "Stash Changes and Continue" stashes, then runs the operation: a
    /// caller that answers the operation's questions and runs it again
    /// runs the two steps itself (`stashChanges(in:confirmed:)`, then the
    /// operation), so the changes are stashed once. "Clear Old Rebase and
    /// Continue" likewise (`clearLeftoverRebase(in:)`).
    @discardableResult
    @MainActor
    public func perform(in app: AppModel, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> OperationOutcome {
        switch self {
        case .retry(let operation):
            return try await operation.perform(in: app, confirmed: confirmed)

        case .stashChangesAndRetry(_, let operation):
            guard try await stashChanges(in: app, confirmed: confirmed) else {
                return .nothing
            }
            return try await operation.perform(in: app, confirmed: confirmed)

        case .clearLeftoverRebaseAndRetry(_, let operation):
            try await clearLeftoverRebase(in: app)
            return try await operation.perform(in: app, confirmed: confirmed)

        case .fetch(let id):
            try await app.requireRepository(id, for: .fetch).sync.fetch()

        case .discardPermanently(let id, let files):
            try await app.requireRepository(id, for: .discardChanges).changes.discard(
                files,
                permanently: true,
                confirmed: [.discardChanges, .discardAllChanges]
            )

        case .updateLFSFilters:
            try await app.integrations.updateGlobalLFSFilters()

        case .editGlobalGitConfig:
            try await app.integrations.editGlobalGitConfig()

        case .downloadSuggestedEditor:
            if let url = URL(string: suggestedExternalEditor.url) {
                _ = app.environment.workspace.open(url)
            }

        case .requestOrganizationAccess(let url):
            _ = app.environment.workspace.open(url)

        case .createFork, .signIn, .reviewPushProtection, .openSettings:
            throw OperationError(.precondition("This needs to be done in Espalier's window."), operation: .push)
        }
        return .nothing
    }
}

extension Recovery {
    /// "Stash Changes and Continue"'s first step: stashes the changes as the
    /// current branch's stash, without asking: the recovery is offered only
    /// when the branch has no stash. A stash made meanwhile still asks
    /// (`.overwriteStash`). Nothing for other recoveries.
    ///
    /// - Returns: Whether the changes were stashed, so the operation runs.
    @MainActor
    public func stashChanges(in app: AppModel, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> Bool {
        guard case .stashChangesAndRetry(let id, let operation) = self else {
            return false
        }
        let repository = try app.requireRepository(id, for: operation.kind)
        return try await repository.stash.stashAllChanges(confirmed: confirmed)
    }

    /// "Clear Old Rebase and Continue"'s first step: clears the rebase's
    /// state (`clearLeftoverRebase()`), which asks nothing. Nothing for
    /// other recoveries.
    @MainActor
    public func clearLeftoverRebase(in app: AppModel) async throws(OperationError) {
        guard case .clearLeftoverRebaseAndRetry(let id, let operation) = self else {
            return
        }
        try await app.requireRepository(id, for: operation.kind).operations.clearLeftoverRebase()
    }
}

extension AppModel {
    /// The repository's model, or a precondition error naming the operation.
    func requireRepository(_ id: RepositoryID, for operation: OperationKind) throws(OperationError) -> RepositoryModel {
        guard let repository = repository(id) else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: operation, repositoryID: id)
        }
        return repository
    }
}

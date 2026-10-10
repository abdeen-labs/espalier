import EspalierSupport
import Foundation
import GitKit

/// Whose name and email a repository's commits use.
public enum GitConfigLocation: Sendable, Hashable, CaseIterable {
    /// "Use my global Git config".
    case global
    /// "Use a local Git config".
    case local

    /// The choices' labels.
    public var title: String {
        switch self {
        case .global: "Use my global Git config"
        case .local: "Use a local Git config"
        }
    }
}

/// A repository's author settings, as Repository Settings loads them.
public struct RepositoryGitAuthor: Sendable, Equatable {
    /// The repository's own `user.name` and `user.email`, nil when unset.
    public var localName: String?
    public var localEmail: String?
    /// The global ones, empty when unset.
    public var globalName: String
    public var globalEmail: String

    public init(localName: String?, localEmail: String?, globalName: String, globalEmail: String) {
        self.localName = localName
        self.localEmail = localEmail
        self.globalName = globalName
        self.globalEmail = globalEmail
    }

    /// The global config, unless the repository sets either value.
    public var location: GitConfigLocation {
        localName == nil && localEmail == nil ? .global : .local
    }

    /// The name the form starts with for a location: the global one, or the
    /// repository's own (the global one when it has none: a switch to Local
    /// starts from what's shown).
    public func name(for location: GitConfigLocation) -> String {
        switch location {
        case .global: globalName
        case .local: localName ?? (self.location == .global ? globalName : "")
        }
    }

    /// The email the form starts with for a location, as `name(for:)`.
    public func email(for location: GitConfigLocation) -> String {
        switch location {
        case .global: globalEmail
        case .local: localEmail ?? (self.location == .global ? globalEmail : "")
        }
    }
}

extension RepositoryModel {
    /// The repository's own author (`user.name` and `user.email` with
    /// `--local`) and the global one.
    ///
    /// - Throws: Git's error when the configuration can't be read.
    public func loadGitAuthor() async throws(OperationError) -> RepositoryGitAuthor {
        let repository = gitRepository
        do {
            return try await environment.withRuntimes {
                async let localName = getConfigValue(repository, "user.name", onlyLocal: true)
                async let localEmail = getConfigValue(repository, "user.email", onlyLocal: true)
                async let globalName = getGlobalConfigValue("user.name")
                async let globalEmail = getGlobalConfigValue("user.email")
                return RepositoryGitAuthor(
                    localName: try await localName,
                    localEmail: try await localEmail,
                    globalName: try await globalName ?? "",
                    globalEmail: try await globalEmail ?? ""
                )
            }
        } catch {
            throw await ErrorClassifier.classify(
                error,
                descriptor: OperationDescriptor(kind: .setRepositoryGitConfig, lanes: []),
                record: record,
                context: ClassificationContext()
            )
        }
    }

    /// Saves who commits in the repository, given what `loadGitAuthor()`
    /// loaded:
    ///
    /// - `.global` removes the repository's own `user.name` and
    ///   `user.email`, those it has;
    /// - `.local` sets each value that differs from the repository's own.
    ///   Both must be given, and the name must be one git accepts: an empty
    ///   value breaks committing.
    ///
    /// Then the repository reloads its author. Nothing is written when
    /// nothing changed.
    ///
    /// - Throws: `.precondition` for a missing or invalid value; git's error
    ///   when the configuration can't be written; `busy` while another
    ///   operation runs here.
    public func saveGitAuthor(
        _ location: GitConfigLocation,
        name: String,
        email: String,
        loaded: RepositoryGitAuthor
    ) async throws(OperationError) {
        var writes: [(key: String, value: String?)] = []
        switch location {
        case .global:
            if loaded.localName != nil {
                writes.append(("user.name", nil))
            }
            if loaded.localEmail != nil {
                writes.append(("user.email", nil))
            }
        case .local:
            guard !JSCompat.trim(name).isEmpty, gitAuthorNameIsValid(name) else {
                throw OperationError(
                    .precondition(JSCompat.trim(name).isEmpty ? "Enter a name for this repository's commits." : invalidGitAuthorNameMessage),
                    operation: .setRepositoryGitConfig,
                    repositoryID: id
                )
            }
            guard !JSCompat.trim(email).isEmpty else {
                throw OperationError(.precondition("Enter an email for this repository's commits."), operation: .setRepositoryGitConfig, repositoryID: id)
            }
            if !(loaded.localName.map { JSCompat.strictEquals($0, name) } ?? false) {
                writes.append(("user.name", name))
            }
            if !(loaded.localEmail.map { JSCompat.strictEquals($0, email) } ?? false) {
                writes.append(("user.email", email))
            }
        }
        guard !writes.isEmpty else {
            return
        }

        let descriptor = OperationDescriptor(kind: .setRepositoryGitConfig, refreshAfter: .metadata)
        try await perform(descriptor) { ctx in
            for write in writes {
                if let value = write.value {
                    try await setConfigValue(ctx.repository, write.key, value)
                } else {
                    try await removeConfigValue(ctx.repository, write.key)
                }
            }
        }
        await awaitOperationRefresh(covering: .metadata)
    }
}

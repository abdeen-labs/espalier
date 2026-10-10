// Ported from desktop/app/src/models/github-repository.ts

/// The user's permission level on a GitHub repository.
public enum GitHubRepositoryPermission: String, Codable, Sendable, Hashable {
    case read
    case write
    case admin
}

/// A GitHub repository.
public struct GitHubRepository: Codable, Sendable, Hashable {
    public let name: String
    public let owner: Owner

    /// The ID of the repository in the app's local database. This is no relation
    /// to the API ID.
    public let dbID: Int

    public let isPrivate: Bool?
    public let htmlURL: String?
    public let cloneURL: String?
    public let issuesEnabled: Bool?
    public let isArchived: Bool?

    /// The user's permissions for this github repository. `nil` if unknown.
    public let permissions: GitHubRepositoryPermission?

    private let parentStorage: Parent?

    public init(
        name: String,
        owner: Owner,
        dbID: Int,
        isPrivate: Bool? = nil,
        htmlURL: String? = nil,
        cloneURL: String? = nil,
        issuesEnabled: Bool? = nil,
        isArchived: Bool? = nil,
        permissions: GitHubRepositoryPermission? = nil,
        parent: GitHubRepository? = nil
    ) {
        self.name = name
        self.owner = owner
        self.dbID = dbID
        self.isPrivate = isPrivate
        self.htmlURL = htmlURL
        self.cloneURL = cloneURL
        self.issuesEnabled = issuesEnabled
        self.isArchived = isArchived
        self.permissions = permissions
        parentStorage = parent.map(Parent.init)
    }

    /// The repository this one is a fork of.
    public var parent: GitHubRepository? {
        parentStorage?.repository
    }

    public var endpoint: String {
        owner.endpoint
    }

    /// Get the owner/name combo.
    public var fullName: String {
        "\(owner.login)/\(name)"
    }

    /// Is the repository a fork?
    public var fork: Bool {
        parent != nil
    }

    private enum CodingKeys: String, CodingKey {
        case name, owner, dbID, isPrivate, htmlURL, cloneURL, issuesEnabled, isArchived, permissions
        case parentStorage = "parent"
    }

    /// Boxes the parent, since a struct can't contain itself.
    private final class Parent: Codable, Sendable, Hashable {
        let repository: GitHubRepository

        init(_ repository: GitHubRepository) {
            self.repository = repository
        }

        init(from decoder: any Decoder) throws {
            repository = try GitHubRepository(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try repository.encode(to: encoder)
        }

        static func == (lhs: Parent, rhs: Parent) -> Bool {
            lhs.repository == rhs.repository
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(repository)
        }
    }
}

/// Can the user push to this GitHub repository?
///
/// (If their permissions are unknown, we assume they can.)
public func hasWritePermission(_ gitHubRepository: GitHubRepository) -> Bool {
    gitHubRepository.permissions == nil || gitHubRepository.permissions != .read
}

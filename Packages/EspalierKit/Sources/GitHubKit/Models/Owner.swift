// Ported from desktop/app/src/models/owner.ts

/// The owner of a GitHubRepository.
public struct Owner: Codable, Sendable, Hashable {
    public let login: String
    public let endpoint: String

    /// The database ID. This may be null if the object wasn't retrieved from the database.
    public let id: Int?

    public let type: GitHubAccountType?

    public init(login: String, endpoint: String, id: Int?, type: GitHubAccountType? = nil) {
        self.login = login
        self.endpoint = endpoint
        self.id = id
        self.type = type
    }
}

// Ported from desktop/app/src/models/git-account.ts

/// An account which can be used to potentially authenticate with a git server.
public struct GitAccount: Sendable, Hashable {
    /// The login/username to authenticate with.
    public let login: String

    /// The endpoint with which the user is authenticating.
    public let endpoint: String

    /// The token/password to authenticate with
    public let token: String

    public init(login: String, endpoint: String, token: String) {
        self.login = login
        self.endpoint = endpoint
        self.token = token
    }
}

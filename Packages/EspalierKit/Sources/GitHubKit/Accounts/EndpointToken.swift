// Ported from desktop/app/src/lib/endpoint-token.ts

/// A token and the endpoint it belongs to.
public struct EndpointToken: Sendable, Hashable {
    public let endpoint: String
    public let token: String

    public init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }
}

// Ported from desktop/app/src/ui/lib/enterprise-validate-url.ts

import Foundation

/// Why an enterprise address was rejected.
public struct EnterpriseURLValidationError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// The name for errors thrown because of an invalid URL.
        case invalidURL = "invalid-url"
        /// The name for errors thrown because of an invalid protocol.
        case invalidProtocol = "invalid-protocol"
    }

    public let kind: Kind

    /// The error's own message (`Unknown address`, `Invalid URL`, or
    /// `Invalid protocol`).
    public let message: String

    /// The message sign-in shows for this kind of error.
    public var errorDescription: String? {
        switch kind {
        case .invalidURL:
            "That doesn't look like a valid address. Enter one like https://example.ghe.com."
        case .invalidProtocol:
            "Only https addresses are supported for GitHub Enterprise."
        }
    }
}

/// Validate the URL for a GitHub Enterprise instance.
///
/// Returns the validated URL, or throws if the URL cannot be validated.
public func validateURL(_ address: String) throws -> String {
    var address = address

    // ensure user has specified text and not just whitespace
    // we will interact with this server so we can be fairly
    // relaxed here about what we accept for the server name
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        throw EnterpriseURLValidationError(kind: .invalidURL, message: "Unknown address")
    }

    var url = ParsedURL(trimmed)
    if url.host == nil {
        // E.g., if they user entered 'ghe.io', let's assume they're using https.
        address = "https://\(trimmed)"
        url = ParsedURL(address)
    }

    guard let urlProtocol = url.protocol else {
        throw EnterpriseURLValidationError(kind: .invalidURL, message: "Invalid URL")
    }

    if urlProtocol != "https:" {
        throw EnterpriseURLValidationError(kind: .invalidProtocol, message: "Invalid protocol")
    }

    return address
}

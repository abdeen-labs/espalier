import Foundation

/// A repository's identity: assigned when the repository is added to the
/// list and never changed. Every per-repository object, cache, and stored
/// row is keyed by it, so renaming, relocating, or reassociating a
/// repository keeps its state.
///
/// It encodes as the UUID's string.
public struct RepositoryID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// A new, unique ID.
    public init() {
        rawValue = UUID()
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue.uuidString
    }
}

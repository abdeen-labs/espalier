/// An error a model throws, for example when a Git identity string can't be
/// parsed.
public struct ModelError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

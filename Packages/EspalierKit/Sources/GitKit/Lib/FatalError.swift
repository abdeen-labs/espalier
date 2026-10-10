// Ported from desktop/app/src/lib/fatal-error.ts

import Foundation

/// The error GitKit throws with just a message, for example when git's
/// output can't be parsed.
public struct GitLibError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Unwrap a value that, according to the type system, could be null or
/// undefined, but which we know is not. If the value _is_ null or undefined,
/// this will throw. The message should contain the rationale for knowing the
/// value is defined.
public func forceUnwrap<T>(_ message: String, _ x: T?) throws(GitLibError) -> T {
    guard let x else {
        throw GitLibError(message)
    }
    return x
}

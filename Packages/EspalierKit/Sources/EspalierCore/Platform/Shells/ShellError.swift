// Ported from desktop/app/src/lib/shells/error.ts

import Foundation

/// An error from launching a shell, reported as "Unable to Open Shell"
/// with a button that opens Settings.
public struct ShellError: Error, LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

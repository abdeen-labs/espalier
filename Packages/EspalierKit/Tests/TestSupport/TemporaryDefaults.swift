// Tests never touch `UserDefaults.standard`.

import EspalierSupport
import Foundation

/// A `UserDefaults` domain for one test.
///
/// The domain is named by a path in a temporary directory, which keeps its
/// file out of `~/Library/Preferences`. Remove it when the test is done:
///
/// ```swift
/// let temporary = try TemporaryDefaults()
/// defer { temporary.remove() }
/// ```
public struct TemporaryDefaults: @unchecked Sendable {
    // `@unchecked`: Apple documents `UserDefaults` as thread-safe.

    public let defaults: UserDefaults
    public let suiteName: String

    public init() throws {
        suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestSupportError("Could not create the defaults domain \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Removes everything stored in the domain.
    public func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

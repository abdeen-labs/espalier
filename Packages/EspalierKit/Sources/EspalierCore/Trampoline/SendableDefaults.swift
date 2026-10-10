import Foundation

/// `UserDefaults` for storage in `Sendable` types. Apple documents the class
/// as thread-safe, but the SDK doesn't mark it `Sendable`.
struct SendableDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

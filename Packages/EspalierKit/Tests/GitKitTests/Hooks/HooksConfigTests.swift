import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("hooks/config")
struct HooksConfigTests {
    /// Runs `body` with an empty defaults domain of its own. The suite name
    /// is a path, so the domain's file goes in a temporary directory rather
    /// than ~/Library/Preferences, where removing the domain leaves an empty
    /// file behind.
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = POSIXPath.join(try createTempDirectory(), "defaults")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    // The defaults, the keys, and the setters are checked through
    // Preferences, which stores these settings (PreferencesTests).
    @Test("reads desktop's stored strings, else the default")
    func readsDesktopStrings() throws {
        try withDefaults { defaults in
            for (stored, expected) in [("1", true), ("true", true), ("0", false), ("false", false), ("no", true)] {
                defaults.set(stored, forKey: "git-hooks-env-enabled")
                defaults.set(stored, forKey: "git-cache-hooks-env")
                #expect(getHooksEnvEnabled(defaults: defaults) == expected, "\(stored)")
                #expect(getCacheHooksEnv(defaults: defaults) == expected, "\(stored)")
            }
        }
    }
}

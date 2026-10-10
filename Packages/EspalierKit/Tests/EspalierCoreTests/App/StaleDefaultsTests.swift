// Launch removes the keys earlier builds left in the defaults, and nothing
// else.

@testable import EspalierCore
import Foundation
import Testing
import TestSupport

@Suite("Stale defaults") @MainActor
struct StaleDefaultsTests {
    @Test("launch removes the old main window frame, keeping the other keys")
    func removesStaleKeys() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let defaults = temporary.defaults
        defaults.set("100 100 1200 800 0 0 1728 1079 ", forKey: "NSWindow Frame EspalierMainWindow")
        defaults.set("0 0 1200 800 0 0 1728 1079 ", forKey: "NSWindow Frame main")
        defaults.set(true, forKey: "confirmForcePush")

        AppBootstrap.removeStaleDefaults(from: defaults)
        #expect(defaults.object(forKey: "NSWindow Frame EspalierMainWindow") == nil)
        #expect(defaults.string(forKey: "NSWindow Frame main") == "0 0 1200 800 0 0 1728 1079 ")
        #expect(defaults.bool(forKey: "confirmForcePush"))

        // Again, with nothing left to remove.
        AppBootstrap.removeStaleDefaults(from: defaults)
        #expect(defaults.object(forKey: "NSWindow Frame EspalierMainWindow") == nil)
    }
}

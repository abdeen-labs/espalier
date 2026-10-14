// The AI conflict sheet's Changes tab keeps a file's diff only for that
// file while the next loads.

import GitKit
import Testing
@testable import EspalierUI

@Suite("AI resolution changes") @MainActor
struct AIResolutionChangesTests {
    private let diff = ResolutionDiff(diff: .binary, oldContents: "", newContents: "")

    @Test("another file's diff shows as loading, and is dropped when the next file loads")
    func anotherFile() {
        let state = ResolutionDiffState.loaded(diff, path: "a.txt")
        #expect(state.shown(for: "b.txt") == .loading)
        #expect(state.reloading("b.txt") == .loading)
        #expect(ResolutionDiffState.failed("No luck", path: "a.txt").shown(for: "b.txt") == .loading)
    }

    @Test("the file's own diff shows while it reloads")
    func sameFile() {
        let state = ResolutionDiffState.loaded(diff, path: "a.txt")
        #expect(state.shown(for: "a.txt") == state)
        #expect(state.reloading("a.txt") == state)
    }
}

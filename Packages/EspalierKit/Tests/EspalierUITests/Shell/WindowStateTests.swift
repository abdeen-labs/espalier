// The window's toolbar search: selecting another place or another
// repository clears it; selecting the same place in the same repository
// keeps it.

import EspalierCore
import Testing
@testable import EspalierUI

@Suite("Window state") @MainActor
struct WindowStateTests {
    @Test("the toolbar search clears when the repository or the place changes, and stays otherwise")
    func searchClears() {
        let state = WindowState()
        let first = RepositoryID(), second = RepositoryID()
        state.select(.history, in: first)

        state.searchText = "fix"
        state.select(.history, in: first)
        #expect(state.searchText == "fix")

        state.select(.history, in: second)
        #expect(state.searchText.isEmpty)

        state.searchText = "fix"
        state.select(.changes, in: second)
        #expect(state.searchText.isEmpty)
    }
}

// A branch group's expansion: the group's choice, the remembered one, and
// the filter holding it open.

import Testing
@testable import EspalierUI

@Suite("Branch groups")
struct BranchGroupDisclosureTests {
    @Test("a group shows its rows as last set, else as remembered, and always while filtering")
    func isOpen() {
        #expect(BranchGroupExpansion.isOpen(chosen: nil, remembered: true, isFiltering: false))
        #expect(!BranchGroupExpansion.isOpen(chosen: nil, remembered: false, isFiltering: false))
        #expect(!BranchGroupExpansion.isOpen(chosen: false, remembered: true, isFiltering: false))
        #expect(BranchGroupExpansion.isOpen(chosen: true, remembered: false, isFiltering: false))
        #expect(BranchGroupExpansion.isOpen(chosen: false, remembered: false, isFiltering: true))
    }

    @Test("opening or closing changes the expansion, except to what it is or while the filter holds it open")
    func change() {
        #expect(BranchGroupExpansion.change(to: true, from: false, isFiltering: false) == true)
        #expect(BranchGroupExpansion.change(to: false, from: true, isFiltering: false) == false)
        // Opening an open group, closing a closed one.
        #expect(BranchGroupExpansion.change(to: true, from: true, isFiltering: false) == nil)
        #expect(BranchGroupExpansion.change(to: false, from: false, isFiltering: false) == nil)
        #expect(BranchGroupExpansion.change(to: false, from: true, isFiltering: true) == nil)
    }
}

// Ported from desktop/app/test/unit/worktree-dropdown-test.ts
// Each case's expected value is written out rather than computed with the
// function's own formula. Desktop's cases for 0 and 3 worktrees repeat
// those for 1 and 2.

import EspalierCore
import Testing
import TestSupport

private let cases: [NamedCase<(count: Int, isOpen: Bool, alwaysShow: Bool, expected: Bool)>] = [
    NamedCase("handles 1 worktrees, open=false, always show=false", (count: 1, isOpen: false, alwaysShow: false, expected: false)),
    NamedCase("handles 1 worktrees, open=false, always show=true", (count: 1, isOpen: false, alwaysShow: true, expected: true)),
    NamedCase("handles 1 worktrees, open=true, always show=false", (count: 1, isOpen: true, alwaysShow: false, expected: true)),
    NamedCase("handles 2 worktrees, open=false, always show=false", (count: 2, isOpen: false, alwaysShow: false, expected: true)),
]

@Suite("shouldShowWorktreeDropdown")
struct WorktreeDropdownTests {
    @Test("handles worktrees, open, always show", arguments: cases)
    func handles(_ testCase: NamedCase<(count: Int, isOpen: Bool, alwaysShow: Bool, expected: Bool)>) {
        let (count, isOpen, alwaysShow, expected) = testCase.value
        #expect(shouldShowWorktreeDropdown(count, isOpen, alwaysShow) == expected)
    }
}

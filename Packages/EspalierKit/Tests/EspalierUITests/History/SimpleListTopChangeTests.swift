// Which of the simple list's changes slide at its top: a few commits made
// (arriving) or undone (leaving) with every row below the same, an expanded
// merge's rows included. Any other change shows at once.

import EspalierCore
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Simple list's commits arriving and leaving at the top") @MainActor
struct SimpleListTopChangeTests {
    struct Case: Sendable {
        var old: [SimpleHistoryItem]
        var oldTop: [String]
        var new: [SimpleHistoryItem]
        var newTop: [String]
        /// The commits no longer in the history.
        var gone: Set<String> = []
        var expected: SimpleListController.TopChange?
    }

    /// The line's first `count` commits, one row each.
    nonisolated static func commits(_ count: Int) -> [SimpleHistoryItem] {
        (0..<count).map { .commit(row: $0) }
    }

    @Test("the change that slides", arguments: [
        NamedCase("a commit made", Case(
            old: commits(3), oldTop: ["a", "b", "c"],
            new: commits(4), newTop: ["n", "a", "b", "c"],
            expected: SimpleListController.TopChange(inserted: 1)
        )),
        NamedCase("two commits made, the page dropping its last rows", Case(
            old: commits(4), oldTop: ["a", "b", "c", "d"],
            new: commits(4), newTop: ["m", "n", "a", "b"],
            expected: SimpleListController.TopChange(inserted: 2)
        )),
        NamedCase("a commit made above an expanded merge", Case(
            old: [.commit(row: 0), .commit(row: 1), .mergedCommit(mergeRow: 1, index: 0), .mergedCommitsStatus(mergeRow: 1), .commit(row: 2)],
            oldTop: ["a", "b", "c"],
            new: [.commit(row: 0), .commit(row: 1), .commit(row: 2), .mergedCommit(mergeRow: 2, index: 0), .mergedCommitsStatus(mergeRow: 2), .commit(row: 3)],
            newTop: ["n", "a", "b", "c"],
            expected: SimpleListController.TopChange(inserted: 1)
        )),
        NamedCase("a commit undone", Case(
            old: commits(3), oldTop: ["a", "b", "c"],
            new: commits(2), newTop: ["b", "c"],
            gone: ["a"],
            expected: SimpleListController.TopChange(removed: 1)
        )),
        NamedCase("the first commit replaced", Case(
            old: commits(3), oldTop: ["a", "b", "c"],
            new: commits(3), newTop: ["z", "b", "c"],
            gone: ["a"],
            expected: nil
        )),
        NamedCase("the first commits reordered", Case(
            old: commits(3), oldTop: ["a", "b", "c"],
            new: commits(3), newTop: ["b", "c", "a"],
            expected: nil
        )),
        NamedCase("a commit left the top but not the history", Case(
            old: commits(3), oldTop: ["a", "b", "c"],
            new: commits(2), newTop: ["b", "c"],
            expected: nil
        )),
        NamedCase("a merge below collapsed", Case(
            old: [.commit(row: 0), .commit(row: 1), .mergedCommit(mergeRow: 1, index: 0), .commit(row: 2)],
            oldTop: ["a", "b", "c"],
            new: commits(4), newTop: ["n", "a", "b", "c"],
            expected: nil
        )),
        NamedCase("more than three commits made", Case(
            old: commits(2), oldTop: ["a", "b"],
            new: commits(6), newTop: ["q", "p", "o", "n"],
            expected: nil
        )),
    ])
    func topChange(_ change: NamedCase<Case>) {
        let value = change.value
        let result = SimpleListController.topChange(
            from: value.old,
            oldTop: value.oldTop,
            to: value.new,
            newTop: value.newTop,
            isGone: { value.gone.contains($0) }
        )
        #expect(result == value.expected)
    }
}

// A branch row animates a change only to what it already showed: a count
// changing, a push clearing it, checks finishing. A comparison or checks
// loading (a row scrolled into view) and a pull request arriving or leaving
// show at once.

import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch row marks")
struct BranchRowMarksTests {
    /// The marks before and after, and whether the change animates.
    typealias Case = (old: Marks, new: Marks, animates: Bool)

    /// A row's pull request and comparison.
    struct Marks: Sendable {
        var pullRequest: BranchPullRequestBadge?
        var tracking: BranchTracking
    }

    private static func marks(_ marks: Marks) -> BranchRowMarks {
        BranchRowMarks(BranchRowContent(ref: "refs/heads/feature", name: "feature", tracking: marks.tracking, pullRequest: marks.pullRequest))
    }

    static func pullRequest(_ number: Int = 142, checks: ChecksState?) -> BranchPullRequestBadge {
        BranchPullRequestBadge(number: number, isDraft: false, checks: checks)
    }

    @Test("animates only a change to what the row showed", arguments: [
        NamedCase("a commit adding to the count", (
            old: Marks(tracking: .aheadBehind(ahead: 1, behind: 0)), new: Marks(tracking: .aheadBehind(ahead: 2, behind: 0)), animates: true
        )),
        NamedCase("a push clearing the count", (
            old: Marks(tracking: .aheadBehind(ahead: 2, behind: 0)), new: Marks(tracking: .aheadBehind(ahead: 0, behind: 0)), animates: true
        )),
        NamedCase("a branch published", (
            old: Marks(tracking: .notPublished), new: Marks(tracking: .aheadBehind(ahead: 0, behind: 0)), animates: true
        )),
        NamedCase("the comparison loading", (
            old: Marks(tracking: .none), new: Marks(tracking: .aheadBehind(ahead: 3, behind: 1)), animates: false
        )),
        NamedCase("checks finishing", (
            old: Marks(pullRequest: pullRequest(checks: .pending), tracking: .none),
            new: Marks(pullRequest: pullRequest(checks: .success), tracking: .none),
            animates: true
        )),
        NamedCase("checks loading", (
            old: Marks(pullRequest: pullRequest(checks: nil), tracking: .none),
            new: Marks(pullRequest: pullRequest(checks: .pending), tracking: .none),
            animates: false
        )),
        NamedCase("a pull request arriving", (
            old: Marks(tracking: .aheadBehind(ahead: 1, behind: 0)),
            new: Marks(pullRequest: pullRequest(checks: .pending), tracking: .aheadBehind(ahead: 1, behind: 0)),
            animates: false
        )),
        NamedCase("another pull request", (
            old: Marks(pullRequest: pullRequest(141, checks: .success), tracking: .none),
            new: Marks(pullRequest: pullRequest(checks: .success), tracking: .none),
            animates: false
        )),
    ] as [NamedCase<Case>])
    func animates(_ testCase: NamedCase<Case>) {
        let value = testCase.value
        #expect(Self.marks(value.new).animates(from: Self.marks(value.old)) == value.animates)
    }
}

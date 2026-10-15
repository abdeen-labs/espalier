// New Branch and Rename Branch refuse a name git can't keep beside the
// local branches: one of them in another case, or one that is another's
// folder (`feature` and `feature/x`). Remote branches live apart, and a
// rename's own branch doesn't count.

import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branch name validation")
struct BranchNameValidationTests {
    /// The repository's local and remote branches, the name typed, a
    /// rename's current name, and whether the name can be used.
    typealias Case = (local: [String], remote: [String], proposed: String, currentName: String?, isValid: Bool)

    private static func branches(_ testCase: Case) -> [Branch] {
        testCase.local.map {
            Branch(name: $0, upstream: nil, tip: BranchTip(sha: String(repeating: "1", count: 40)), type: .local, ref: "refs/heads/\($0)")
        } + testCase.remote.map {
            Branch(name: $0, upstream: nil, tip: BranchTip(sha: String(repeating: "2", count: 40)), type: .remote, ref: "refs/remotes/\($0)")
        }
    }

    @Test("refuses a name that clashes with a local branch", arguments: [
        NamedCase("inside a branch", (local: ["main", "feature"], remote: [], proposed: "feature/x", currentName: nil, isValid: false)),
        NamedCase("around a branch", (local: ["main", "feature/x"], remote: [], proposed: "feature", currentName: nil, isValid: false)),
        NamedCase("a branch in another case", (local: ["main", "feature"], remote: [], proposed: "Feature", currentName: nil, isValid: false)),
        NamedCase("inside a branch in another case", (local: ["main", "feature"], remote: [], proposed: "FEATURE/x", currentName: nil, isValid: false)),
        NamedCase("only starting like a branch", (local: ["main", "feature"], remote: [], proposed: "feature-x/y", currentName: nil, isValid: true)),
        NamedCase("around a remote branch", (local: ["main"], remote: ["origin/feature"], proposed: "origin", currentName: nil, isValid: true)),
        NamedCase("a rename into its own folder", (local: ["main", "feature"], remote: [], proposed: "feature/x", currentName: "feature", isValid: true)),
        NamedCase("a rename into another branch", (local: ["main", "feature"], remote: [], proposed: "main/x", currentName: "feature", isValid: false)),
    ] as [NamedCase<Case>])
    func clashes(_ testCase: NamedCase<Case>) {
        let value = testCase.value
        let validation = BranchNameValidation.validate(value.proposed, branches: Self.branches(value), currentName: value.currentName)
        #expect(validation.isValid == value.isValid)
    }
}

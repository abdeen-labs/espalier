// Ported from desktop/app/test/unit/create-branch-test.ts

import GitKit
import Testing
import TestSupport

private let stubTip = BranchTip(sha: "deadbeef")

private let defaultBranch = Branch(
    name: "my-default-branch",
    upstream: nil,
    tip: stubTip,
    type: .local,
    ref: ""
)

private let upstreamDefaultBranch: Branch? = nil

private let someOtherBranch = Branch(
    name: "some-other-branch",
    upstream: nil,
    tip: stubTip,
    type: .local,
    ref: ""
)

@Suite("create-branch/getStartPoint")
struct CreateBranchTests {
    @Suite("for default branch")
    struct ForDefaultBranch {
        let tip = Tip.valid(branch: defaultBranch)

        @Test("chooses the requested start point", arguments: [
            NamedCase("returns current HEAD when HEAD requested", (requested: StartPoint.head, expected: StartPoint.head)),
            NamedCase("chooses current branch when current branch requested", (requested: .currentBranch, expected: .currentBranch)),
            NamedCase("chooses default branch when default branch requested", (requested: .defaultBranch, expected: .defaultBranch)),
        ])
        func startPoint(_ testCase: NamedCase<(requested: StartPoint, expected: StartPoint)>) {
            let info = BranchInfo(tip: tip, defaultBranch: defaultBranch, upstreamDefaultBranch: upstreamDefaultBranch)
            #expect(getStartPoint(info, testCase.value.requested) == testCase.value.expected)
        }
    }

    @Suite("for detached HEAD")
    struct ForDetachedHead {
        let tip = Tip.detached(currentSha: "deadbeef")

        @Test("always starts from HEAD", arguments: [
            NamedCase("returns current HEAD when default branch requested", (requested: StartPoint.defaultBranch, expected: StartPoint.head)),
        ])
        func startPoint(_ testCase: NamedCase<(requested: StartPoint, expected: StartPoint)>) {
            let info = BranchInfo(tip: tip, defaultBranch: defaultBranch, upstreamDefaultBranch: upstreamDefaultBranch)
            #expect(getStartPoint(info, testCase.value.requested) == testCase.value.expected)
        }
    }

    // MARK: - Espalier

    @Test("falls back to the upstream default branch, the default branch, the current branch, then HEAD")
    func fallbacks() {
        let upstream = Branch(name: "upstream/main", upstream: nil, tip: stubTip, type: .remote, ref: "refs/remotes/upstream/main")
        let valid = Tip.valid(branch: someOtherBranch)

        // A fork's upstream default branch, when there is one.
        #expect(getStartPoint(BranchInfo(tip: valid, defaultBranch: defaultBranch, upstreamDefaultBranch: upstream), .upstreamDefaultBranch) == .upstreamDefaultBranch)
        #expect(getStartPoint(BranchInfo(tip: valid, defaultBranch: defaultBranch, upstreamDefaultBranch: nil), .upstreamDefaultBranch) == .defaultBranch)
        #expect(getStartPoint(BranchInfo(tip: valid, defaultBranch: nil, upstreamDefaultBranch: nil), .defaultBranch) == .currentBranch)
        #expect(getStartPoint(BranchInfo(tip: .unborn(ref: "main"), defaultBranch: nil, upstreamDefaultBranch: nil), .currentBranch) == .head)
        #expect(getStartPoint(BranchInfo(tip: .unknown, defaultBranch: defaultBranch, upstreamDefaultBranch: nil), .currentBranch) == .defaultBranch)
    }
}

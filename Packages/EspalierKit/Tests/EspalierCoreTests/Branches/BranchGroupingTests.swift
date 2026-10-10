// Ported from desktop/app/test/unit/group-branches-test.ts

@testable import EspalierCore
import GitKit
import Testing

@Suite("Branches grouping")
struct BranchGroupingTests {
    let branchTip = BranchTip(sha: "300acef")

    var currentBranch: Branch {
        Branch(name: "master", upstream: nil, tip: branchTip, type: .local, ref: "")
    }

    var defaultBranch: Branch {
        Branch(name: "master", upstream: nil, tip: branchTip, type: .local, ref: "")
    }

    var recentBranches: [Branch] {
        [Branch(name: "some-recent-branch", upstream: nil, tip: branchTip, type: .local, ref: "")]
    }

    var otherBranch: Branch {
        Branch(name: "other-branch", upstream: nil, tip: branchTip, type: .local, ref: "")
    }

    var allBranches: [Branch] {
        [currentBranch] + recentBranches + [otherBranch]
    }

    @Test("should group branches")
    func groups() {
        let groups = groupBranches(defaultBranch, currentBranch, allBranches, recentBranches)
        #expect(groups.count == 3)

        #expect(groups[0].identifier == .defaultBranch)
        var items = groups[0].branches
        #expect(items[0] == defaultBranch)

        #expect(groups[1].identifier == .recent)
        items = groups[1].branches
        #expect(items[0] == recentBranches[0])

        #expect(groups[2].identifier == .other)
        items = groups[2].branches
        #expect(items[0] == otherBranch)
    }

    @Test("without a default branch or recent branches there's only the rest")
    func onlyOthers() {
        let groups = groupBranches(nil, nil, allBranches, [])
        #expect(groups.map(\.identifier) == [.other])
        #expect(groups[0].branches == allBranches)
    }

    @Test("the default branch isn't recent, and fork remotes' branches are left out")
    func filtering() {
        let forkRemoteBranch = Branch(
            name: "\(forkedRemotePrefix)octocat/topic",
            upstream: nil,
            tip: branchTip,
            type: .remote,
            ref: "refs/remotes/\(forkedRemotePrefix)octocat/topic"
        )
        let groups = groupBranches(defaultBranch, currentBranch, allBranches + [forkRemoteBranch], [defaultBranch] + recentBranches)
        #expect(groups.map(\.identifier) == [.defaultBranch, .recent, .other])
        #expect(groups[1].branches == recentBranches)
        #expect(groups[2].branches == [otherBranch])
    }
}

// Ported from desktop/app/test/unit/group-branches-test.ts

@testable import EspalierCore
import EspalierSupport
import GitKit
import Testing

@Suite("Branches grouping")
struct BranchGroupingTests {
    let branchTip = BranchTip(sha: "300acef")

    var currentBranch: Branch {
        Branch(name: "master", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/master")
    }

    var defaultBranch: Branch {
        Branch(name: "master", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/master")
    }

    var recentBranches: [Branch] {
        [Branch(name: "some-recent-branch", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/some-recent-branch")]
    }

    var otherBranch: Branch {
        Branch(name: "other-branch", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/other-branch")
    }

    var allBranches: [Branch] {
        [currentBranch] + recentBranches + [otherBranch]
    }

    @Test("should group branches")
    func groups() {
        let groups = groupBranches(defaultBranch, currentBranch, allBranches, recentBranches, forkRemoteNames: [])
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
        let groups = groupBranches(nil, nil, allBranches, [], forkRemoteNames: [])
        #expect(groups.map(\.identifier) == [.other])
        #expect(groups[0].branches == allBranches)
    }

    @Test("the default branch isn't recent, and the marked fork remotes' branches are left out")
    func filtering() {
        func remoteBranch(_ name: String) -> Branch {
            Branch(name: name, upstream: nil, tip: branchTip, type: .remote, ref: "refs/remotes/\(name)")
        }
        let forkRemoteBranch = remoteBranch("espalier-octocat/topic")
        // Named like one, but not marked: the user's.
        let userRemoteBranch = remoteBranch("espalier-mirror/topic")
        let groups = groupBranches(
            defaultBranch,
            currentBranch,
            allBranches + [forkRemoteBranch, userRemoteBranch],
            [defaultBranch] + recentBranches,
            forkRemoteNames: ["espalier-octocat"].exactSet
        )
        #expect(groups.map(\.identifier) == [.defaultBranch, .recent, .other])
        #expect(groups[1].branches == recentBranches)
        #expect(groups[2].branches == [otherBranch, userRemoteBranch])
    }

    @Test("the current branch shows as the refresh has it, and leads the recent branches while the branch list doesn't have it yet")
    func currentBranch() {
        let refreshed = Branch(name: otherBranch.name, upstream: nil, tip: BranchTip(sha: "4b825dc"), type: .local, ref: otherBranch.ref)
        let shown = groupBranches(defaultBranch, refreshed, allBranches, recentBranches, forkRemoteNames: [])
        #expect(shown.map(\.identifier) == [.defaultBranch, .recent, .other])
        #expect(shown[2].branches == [refreshed])

        let created = Branch(name: "just-created", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/just-created")
        let leading = groupBranches(defaultBranch, created, allBranches, recentBranches, forkRemoteNames: [])
        #expect(leading[1].branches == [created] + recentBranches)
        #expect(leading[2].branches == [otherBranch])
    }

    @Test("a branch shows once by its ref: a local branch named like a remote one shows beside it")
    func refsIdentifyBranches() {
        let local = Branch(name: "origin/topic", upstream: nil, tip: branchTip, type: .local, ref: "refs/heads/origin/topic")
        let remote = Branch(name: "origin/topic", upstream: nil, tip: branchTip, type: .remote, ref: "refs/remotes/origin/topic")
        let groups = groupBranches(nil, nil, [local, remote, local], [local], forkRemoteNames: [])
        #expect(groups.map(\.identifier) == [.recent, .other])
        #expect(groups[0].branches == [local])
        #expect(groups[1].branches == [remote])
    }
}

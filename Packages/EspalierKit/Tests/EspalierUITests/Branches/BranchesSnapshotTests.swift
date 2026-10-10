// The Branches section and its rows, the branch picker and popover, and the
// New, Rename, and Delete Branch sheets, one image per layout; the rows and
// the open section in light and dark, the rest in light. Rows, the
// section's rows, the picker's list, and the sheets take values; the
// section's header and the popover use a repository with a remote. The
// states that differ only in words are BranchesContentTests'.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Branches snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchesSnapshotTests {
    private let area = "Branches"
    private let sidebarWidth = Metrics.Column.sidebar.ideal

    // MARK: Rows

    /// A row for each comparison with the upstream and each pull request
    /// glyph, and a name too long for the sidebar.
    private static let rows: [BranchRowContent] = [
        BranchRowContent(ref: "refs/heads/feature/login", name: "feature/login", isCurrent: true, tracking: .aheadBehind(ahead: 2, behind: 3)),
        BranchRowContent(ref: "refs/heads/main", name: "main", tracking: .aheadBehind(ahead: 0, behind: 0)),
        BranchRowContent(ref: "refs/heads/release", name: "release", tracking: .aheadBehind(ahead: 4, behind: 0)),
        BranchRowContent(ref: "refs/heads/sync", name: "sync", tracking: .aheadBehind(ahead: 0, behind: 12)),
        BranchRowContent(ref: "refs/heads/import", name: "import", tracking: .aheadBehind(ahead: 1_234, behind: 12_500)),
        BranchRowContent(ref: "refs/heads/spike", name: "spike", tracking: .notPublished),
        BranchRowContent(ref: "refs/heads/old-feature", name: "old-feature", tracking: .upstreamGone),
        BranchRowContent(
            ref: "refs/heads/onboarding", name: "onboarding", tracking: .aheadBehind(ahead: 1, behind: 0),
            pullRequest: BranchPullRequestBadge(number: 142, isDraft: false, checks: .success)
        ),
        BranchRowContent(ref: "refs/heads/payments", name: "payments", pullRequest: BranchPullRequestBadge(number: 143, isDraft: false, checks: .failure)),
        BranchRowContent(ref: "refs/heads/search", name: "search", pullRequest: BranchPullRequestBadge(number: 144, isDraft: false, checks: .pending)),
        BranchRowContent(ref: "refs/heads/docs", name: "docs", pullRequest: BranchPullRequestBadge(number: 145, isDraft: false, checks: .neutral)),
        BranchRowContent(ref: "refs/heads/redesign", name: "redesign", pullRequest: BranchPullRequestBadge(number: 146, isDraft: false)),
        BranchRowContent(ref: "refs/heads/draft", name: "draft", pullRequest: BranchPullRequestBadge(number: 147, isDraft: true)),
        BranchRowContent(ref: "refs/remotes/origin/experiment", name: "origin/experiment", title: "experiment", isRemote: true),
        BranchRowContent(
            ref: "refs/heads/feature/a-very-long-branch-name-for-the-sidebar",
            name: "feature/a-very-long-branch-name-for-the-sidebar",
            tracking: .aheadBehind(ahead: 3, behind: 1),
            pullRequest: BranchPullRequestBadge(number: 148, isDraft: false, checks: .success)
        ),
    ]

    @Test("rows: the current branch, each comparison with the upstream, and pull requests with their checks")
    func rows() {
        let view = List {
            ForEach(Self.rows) { row in
                BranchRow(row)
            }
        }
        .sidebarListStyle()
        .frame(width: sidebarWidth, height: 500)
        assertSnapshot(view, named: "rows", area: area)
    }

    // MARK: The section

    /// The section's branches: the current one ahead and behind, the
    /// default one in sync, a recent one with a pull request, others in a
    /// folder, and a remote's.
    private static func sectionInputs(filter: String = "") -> BranchesSectionContent.Inputs {
        let repository = gitHubRepoFixture(owner: "octo-org", name: "website")
        let main = localBranch("main", sha: sha(1), upstream: "origin/main")
        let login = localBranch("feature/login", sha: sha(2), upstream: "origin/feature/login")
        let onboarding = localBranch("onboarding", sha: sha(3), upstream: "origin/onboarding")
        let signup = localBranch("feature/signup", sha: sha(4))
        let colors = localBranch("feature/ui/colors", sha: sha(5), upstream: "origin/feature/ui/colors")
        let spike = localBranch("spike", sha: sha(6))
        let old = localBranch("old-feature", sha: sha(7), upstream: "origin/old-feature")
        let remotes = [remoteBranch("origin/experiment", sha: sha(8)), remoteBranch("origin/release/1.0", sha: sha(9))]
        return BranchesSectionContent.Inputs(
            branches: [main, login, onboarding, signup, colors, spike, old] + remotes,
            tip: .valid(branch: login),
            defaultBranch: main,
            recentBranches: [login, onboarding, main],
            currentAheadBehind: AheadBehind(ahead: 2, behind: 3),
            upstreamStates: [
                main.ref: .tracking(AheadBehind(ahead: 0, behind: 0)),
                onboarding.ref: .tracking(AheadBehind(ahead: 1, behind: 0)),
                colors.ref: .tracking(AheadBehind(ahead: 0, behind: 5)),
                old.ref: .gone,
            ],
            pullRequests: [pullRequest(142, head: "onboarding", in: repository)],
            checks: [142: .success],
            remotes: [Remote(name: "origin", url: "https://github.com/octo-org/website.git")],
            filter: filter
        )
    }

    /// A SHA made of one digit.
    private static func sha(_ digit: Int) -> String {
        String(repeating: String(digit), count: 40)
    }

    /// The section in a sidebar list, as the window shows it, with
    /// onboarding selected (its row in the neutral wash, its name medium).
    private func section(
        _ content: BranchesSectionContent,
        context: WindowContext,
        defaults: UserDefaults,
        prunedBranches: [PrunedBranch] = [],
        height: CGFloat
    ) -> some View {
        List {
            SidebarSection(id: "branches") {
                BranchesSectionRows(content: content)
            } header: {
                BranchesSectionHeader(prunedBranches: prunedBranches)
            }
        }
        .sidebarListStyle()
        .environment(\.sidebarSelection, .branch(ref: "refs/heads/onboarding"))
        .frame(width: sidebarWidth, height: height)
        .defaultAppStorage(defaults)
        .windowEnvironment(context)
    }

    @Test("the section: groups collapsed, then open, with a branch selected")
    func section() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture()
            let context = fixture.context
            let content = BranchesSectionContent.make(Self.sectionInputs())
            let pruned = [PrunedBranch(name: "old-cleanup", sha: Self.sha(1), date: UIFixtures.minutesAgo(30))]

            let collapsed = try TemporaryDefaults()
            defer { collapsed.remove() }
            assertSnapshot(
                section(content, context: context, defaults: collapsed.defaults, prunedBranches: pruned, height: 220),
                named: "section-collapsed", area: area, appearances: [.light]
            )

            let expanded = try TemporaryDefaults()
            defer { expanded.remove() }
            for group in ["branches.other", "branches.folder.other:feature", "branches.folder.other:feature/ui", "branches.remote", "branches.remote.origin", "branches.folder.remote/origin:release"] {
                expanded.defaults.set(true, forKey: "sidebar.expanded.\(group)")
            }
            assertSnapshot(
                section(content, context: context, defaults: expanded.defaults, height: 560),
                named: "section-expanded", area: area
            )
        }
    }

    // MARK: The picker and the popover

    /// The picker's branches, their tips a day apart.
    private static let pickerBranches: [Branch] = [
        localBranch("main", sha: sha(1), upstream: "origin/main"),
        localBranch("feature/login", sha: sha(2), upstream: "origin/feature/login"),
        localBranch("fix/crash", sha: sha(3)),
        localBranch("onboarding", sha: sha(4), upstream: "origin/onboarding"),
        localBranch("spike", sha: sha(5)),
        remoteBranch("origin/experiment", sha: sha(6)),
        remoteBranch("origin/release/1.0", sha: sha(7)),
    ]

    private static var pickerDates: [String: Date] {
        Dictionary(uniqueKeysWithValues: (1...7).map { (sha($0), UIFixtures.minutesAgo(Double($0 * $0) * 90)) })
    }

    private func picker(filter: String, selection: Branch?) -> some View {
        let branches = Self.pickerBranches
        let content = BranchPickerContent.make(
            branches: branches,
            defaultBranch: branches[0],
            recentBranches: [branches[1], branches[2]],
            includesRemoteBranches: true,
            filter: filter
        )
        return BranchPickerList(
            content: content,
            currentBranch: "feature/login",
            dates: Self.pickerDates,
            filter: .constant(filter),
            selection: .constant(selection),
            onCreateBranch: { _ in }
        )
        .frame(width: 340, height: 320)
        .padding(Metrics.insetMedium)
    }

    @Test("the picker: grouped with dates and a selection, and a miss with Create New Branch")
    func picker() {
        let branches = Self.pickerBranches
        assertSnapshot(picker(filter: "", selection: branches[3]), named: "picker", area: area, appearances: [.light])
        assertSnapshot(picker(filter: "nothing-like-this", selection: nil), named: "picker-miss", area: area, appearances: [.light])
    }

    @Test("Compare's picker: how far the current branch is behind and ahead of each branch, once counted")
    func comparedPicker() {
        let branches = Self.pickerBranches
        let counts: [String: AheadBehind] = [
            "main": AheadBehind(ahead: 2, behind: 14),
            "fix/crash": AheadBehind(ahead: 3, behind: 1),
            "onboarding": AheadBehind(ahead: 0, behind: 0),
            "spike": AheadBehind(ahead: 1_204, behind: 37),
            "origin/experiment": AheadBehind(ahead: 5, behind: 2),
        ]
        let comparison = BranchComparison(
            currentBranch: "feature/login",
            from: Self.sha(2),
            cached: { counts[$0.name] },
            load: { counts[$0.name] }
        )
        let content = BranchPickerContent.make(
            branches: branches,
            defaultBranch: branches[0],
            recentBranches: [branches[2]],
            includesRemoteBranches: true,
            filter: "",
            candidates: branches.filter { $0.name != "feature/login" }
        )
        let view = BranchPickerList(
            content: content,
            currentBranch: "feature/login",
            dates: Self.pickerDates,
            filter: .constant(""),
            selection: .constant(branches[2]),
            comparison: comparison
        )
        .frame(width: 400, height: 320)
        .padding(Metrics.insetMedium)
        assertSnapshot(view, named: "picker-compared", area: area, appearances: [.light])
        let mainCounts = BranchComparisonCounts(counts["main"]!, currentBranch: "feature/login")
        #expect(mainCounts.text == "↓14 ↑2")
        #expect(mainCounts.description == "feature/login is 14 commits behind and 2 commits ahead")
        #expect(BranchComparisonCounts(AheadBehind(ahead: 1, behind: 1), currentBranch: "main").description == "main is 1 commit behind and 1 commit ahead")
        #expect(BranchComparisonCounts(counts["spike"]!, currentBranch: "main").text == "↓37 ↑1,204")
    }

    @Test("the branch popover: the picker, New Branch…, and Check Out")
    func popover() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture { local in
                try await runGit(["branch", "feature/login"], local)
                try await runGit(["branch", "fix/crash"], local)
            }
            assertSnapshot(BranchPopover(repository: fixture.repository).windowEnvironment(fixture.context), named: "popover", area: area, appearances: [.light])
        }
    }

    // MARK: New, Rename, and Delete

    private static let sheetBranches = [
        localBranch("main", upstream: "origin/main"),
        localBranch("feature/login", upstream: "origin/feature/login"),
        remoteBranch("origin/experiment"),
    ]

    private func newBranchSheet(tip: Tip, defaultBranch: Branch?) -> some View {
        let content = NewBranchSheetContent.make(
            mode: .create,
            tip: tip,
            defaultBranch: defaultBranch,
            upstreamDefaultBranch: nil,
            upstreamRepositoryName: nil,
            isFork: false
        )
        return NewBranchSheet(
            content,
            initialName: "",
            branches: Self.sheetBranches,
            onCreate: { _, _ in },
            onForkBehavior: nil
        )
    }

    @Test("New Branch: the choice between the default and the current branch")
    func newBranch() {
        let main = Self.sheetBranches[0]
        let login = Self.sheetBranches[1]
        assertSnapshot(newBranchSheet(tip: .valid(branch: login), defaultBranch: main), named: "newBranch-choice", area: area, appearances: [.light])
    }

    @Test("the name's messages: the repository's rules, as an error and as a warning")
    func ruleMessages() {
        let branches = Self.sheetBranches
        let restricted = BranchNameValidation.validate("release", branches: branches)
            .adding(BranchNameRuleError(message: "Branch name 'release' is restricted by the repository's rules.", isWarning: false))
        let bypass = BranchNameValidation.validate("my release", branches: branches)
            .adding(BranchNameRuleError(message: "Branch name 'my-release' is restricted by the repository's rules, but you can bypass them.", isWarning: true))
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            NameValidationMessages(restricted)
            Divider()
            NameValidationMessages(bypass)
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Sheet.standardWidth, alignment: .leading)
        assertSnapshot(view, named: "nameMessages", area: area, appearances: [.light])
    }

    @Test("Rename: a tracking branch's warning")
    func rename() {
        assertSnapshot(
            RenameBranchSheet(RenameBranchSheetContent(branchName: "feature/login", upstream: "origin/feature/login"), branches: Self.sheetBranches, onRename: { _ in }),
            named: "rename-tracking", area: area, appearances: [.light]
        )
    }

    @Test("Delete, for a branch with a pull request")
    func deletePullRequestBranch() {
        assertSnapshot(
            DeleteBranchSheet(DeleteBranchSheetContent(branchName: "onboarding", pullRequestNumber: 142), onDelete: {}, onViewPullRequest: {}),
            named: "delete-pullRequest", area: area, appearances: [.light]
        )
    }
}

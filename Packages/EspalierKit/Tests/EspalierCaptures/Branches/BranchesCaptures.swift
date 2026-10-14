// The Branches section and its rows, the branch picker and popover, and the
// New, Rename, and Delete Branch sheets, one capture per layout. Rows, the
// section's rows, the picker's list, and the sheets take values; the
// section's header and the popover use a repository with a remote. Dots
// take the colors the app gives the branches listed (`BranchColors`): the
// section's repository has its local branches, on feature/login.

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

@Suite("Branches", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct BranchesCaptures {
    private let area = "Branches"
    private let sidebarWidth = Metrics.Column.sidebar.ideal
    private typealias Values = BranchCaptureValues

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
        let colors = BranchColors(
            branches: Self.rows.filter { !$0.isRemote }.map(\.name),
            current: "feature/login",
            defaultBranch: "main",
            remoteNames: ["origin"]
        )
        let view = List {
            ForEach(Self.rows) { row in
                BranchRow(row, dotColor: colors.color(of: (name: row.name, isRemote: row.isRemote)))
            }
        }
        .sidebarListStyle()
        .frame(width: sidebarWidth, height: 500)
        capture(view, named: "rows", area: area)
    }

    // MARK: The section

    /// The section's branches: the current one ahead and behind, the
    /// default one in sync, a recent one with a pull request, others in a
    /// folder, and a remote's.
    private static func sectionInputs() -> BranchesSectionContent.Inputs {
        let repository = gitHubRepoFixture(owner: "octo-org", name: "website")
        let main = Values.localBranch("main", sha: Values.sha(1), upstream: "origin/main")
        let login = Values.localBranch("feature/login", sha: Values.sha(2), upstream: "origin/feature/login")
        let onboarding = Values.localBranch("onboarding", sha: Values.sha(3), upstream: "origin/onboarding")
        let signup = Values.localBranch("feature/signup", sha: Values.sha(4))
        let colors = Values.localBranch("feature/ui/colors", sha: Values.sha(5), upstream: "origin/feature/ui/colors")
        let spike = Values.localBranch("spike", sha: Values.sha(6))
        let old = Values.localBranch("old-feature", sha: Values.sha(7), upstream: "origin/old-feature")
        let remotes = [Values.remoteBranch("origin/experiment", sha: Values.sha(8)), Values.remoteBranch("origin/release/1.0", sha: Values.sha(9))]
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
            pullRequests: [Values.pullRequest(142, head: "onboarding", in: repository)],
            checks: [142: .success],
            remotes: [Remote(name: "origin", url: "https://github.com/octo-org/website.git")],
            filter: ""
        )
    }

    /// The section in a sidebar list, as the window shows it, with
    /// onboarding selected (its row in the neutral wash, its name medium).
    private func section(
        _ content: BranchesSectionContent,
        fixture: OperationsCaptureRepository,
        defaults: UserDefaults,
        prunedBranches: [PrunedBranch] = [],
        height: CGFloat
    ) -> some View {
        List {
            SidebarSection(id: "branches") {
                BranchesSectionRows(content: content, repository: fixture.repository)
            } header: {
                BranchesSectionHeader(prunedBranches: prunedBranches)
            }
        }
        .sidebarListStyle()
        .environment(\.sidebarSelection, .branch(ref: "refs/heads/onboarding"))
        .frame(width: sidebarWidth, height: height)
        .defaultAppStorage(defaults)
        .windowEnvironment(fixture.context)
    }

    @Test("the section: as it first shows (Remote Branches and the folders collapsed), then open, with a branch selected")
    func section() async throws {
        try await withIsolatedGitConfig { _ in
            let inputs = Self.sectionInputs()
            let localBranches = inputs.branches.filter { $0.type == .local && $0.name != "main" }.map(\.name)
            let fixture = try await OperationsCaptureRepository.make { local in
                for name in localBranches {
                    try await runGit(["branch", name], local)
                }
                try await runGit(["checkout", "-q", "feature/login"], local)
            }
            let content = BranchesSectionContent.make(inputs)
            let pruned = [PrunedBranch(name: "old-cleanup", sha: Values.sha(1), date: Date().addingTimeInterval(-30 * 60))]

            let firstShown = try TemporaryDefaults()
            defer { firstShown.remove() }
            capture(section(content, fixture: fixture, defaults: firstShown.defaults, prunedBranches: pruned, height: 330), named: "section-default", area: area)

            let expanded = try TemporaryDefaults()
            defer { expanded.remove() }
            for group in ["branches.folder.other:feature", "branches.folder.other:feature/ui", "branches.remote", "branches.remote.origin", "branches.folder.remote/origin:release"] {
                expanded.defaults.set(true, forKey: "sidebar.expanded.\(group)")
            }
            capture(section(content, fixture: fixture, defaults: expanded.defaults, height: 560), named: "section-expanded", area: area)
            await fixture.settle()
        }
    }

    // MARK: The picker and the popover

    /// The picker's branches, their tips further apart the further down.
    private static let pickerBranches: [Branch] = [
        Values.localBranch("main", sha: Values.sha(1), upstream: "origin/main"),
        Values.localBranch("feature/login", sha: Values.sha(2), upstream: "origin/feature/login"),
        Values.localBranch("fix/crash", sha: Values.sha(3)),
        Values.localBranch("onboarding", sha: Values.sha(4), upstream: "origin/onboarding"),
        Values.localBranch("spike", sha: Values.sha(5)),
        Values.remoteBranch("origin/experiment", sha: Values.sha(6)),
        Values.remoteBranch("origin/release/1.0", sha: Values.sha(7)),
    ]

    /// The dots' colors for `branches`, on feature/login, as the app gives
    /// them.
    private static func dotColor(in branches: [Branch]) -> (Branch) -> NSColor {
        let colors = BranchColors(
            branches: branches.filter { $0.type == .local }.map(\.name),
            current: "feature/login",
            defaultBranch: "main",
            remoteNames: ["origin"]
        )
        return { branch in
            colors.color(of: (name: branch.name, isRemote: branch.type == .remote))
        }
    }

    private static var pickerDates: [String: Date] {
        let now = Date()
        return Dictionary(uniqueKeysWithValues: (1...7).map { (Values.sha($0), now.addingTimeInterval(-Double($0 * $0) * 90 * 60)) })
    }

    private func picker(filter: String, selection: Branch?, branches: [Branch] = Self.pickerBranches) -> some View {
        let content = BranchPickerContent.make(
            branches: branches,
            defaultBranch: branches.first,
            recentBranches: Array(branches.dropFirst().prefix(2)),
            forkRemoteNames: [],
            includesRemoteBranches: true,
            filter: filter
        )
        return BranchPickerList(
            content: content,
            currentBranch: "feature/login",
            dates: Self.pickerDates,
            filter: .constant(filter),
            selection: .constant(selection),
            onCreateBranch: { _ in },
            dotColor: Self.dotColor(in: branches)
        )
        .frame(width: 340, height: 320)
        .padding(Metrics.insetMedium)
    }

    @Test("the picker: grouped with dates and a selection, a miss with Create New Branch, and no branches")
    func picker() {
        let branches = Self.pickerBranches
        capture(picker(filter: "", selection: branches[3]), named: "picker", area: area)
        capture(picker(filter: "nothing-like-this", selection: nil), named: "picker-miss", area: area)
        capture(picker(filter: "", selection: nil, branches: []), named: "picker-none", area: area)
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
            from: Values.sha(2),
            cached: { counts[$0.name] },
            load: { counts[$0.name] }
        )
        let content = BranchPickerContent.make(
            branches: branches,
            defaultBranch: branches[0],
            recentBranches: [branches[2]],
            forkRemoteNames: [],
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
            comparison: comparison,
            dotColor: Self.dotColor(in: branches)
        )
        .frame(width: 400, height: 320)
        .padding(Metrics.insetMedium)
        capture(view, named: "picker-compared", area: area)
    }

    @Test("the branch popover, in its card: the picker with the current branch highlighted, New Branch…, and Choose a branch to merge into")
    func popover() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await OperationsCaptureRepository.make { local in
                try await runGit(["branch", "feature/login"], local)
                try await runGit(["branch", "fix/crash"], local)
            }
            // The picker loads its tips' dates as it shows; loaded first,
            // they come from the cache.
            _ = await fixture.repository.branches.tipDates(for: fixture.repository.gitState.branches.all)
            let card = PopoverCardView(model: PopoverCardModel {
                AnyView(BranchPopover(repository: fixture.repository).windowEnvironment(fixture.context))
            })
            await LoadedCapture.capture(card, named: "popover", area: area) { _ in
                await fixture.settle()
            }
        }
    }

    // MARK: New, Rename, and Delete

    private static let sheetBranches = [
        Values.localBranch("main", upstream: "origin/main"),
        Values.localBranch("feature/login", upstream: "origin/feature/login"),
        Values.remoteBranch("origin/experiment"),
    ]

    @Test("New Branch: the choice between the default and the current branch")
    func newBranch() {
        let main = Self.sheetBranches[0]
        let login = Self.sheetBranches[1]
        let content = NewBranchSheetContent.make(
            mode: .create,
            tip: .valid(branch: login),
            defaultBranch: main,
            upstreamDefaultBranch: nil,
            upstreamRepositoryName: nil,
            isFork: false
        )
        let sheet = NewBranchSheet(content, initialName: "", branches: Self.sheetBranches, onCreate: { _, _ in }, onForkBehavior: nil)
        capture(sheet, named: "newBranch-choice", area: area)
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
        capture(view, named: "nameMessages", area: area)
    }

    @Test("Rename: a tracking branch's warning")
    func rename() {
        capture(
            RenameBranchSheet(RenameBranchSheetContent(branchName: "feature/login", upstream: "origin/feature/login"), branches: Self.sheetBranches, onRename: { _ in }),
            named: "rename-tracking", area: area
        )
    }

    @Test("Delete, for a branch with a pull request")
    func deletePullRequestBranch() {
        capture(
            DeleteBranchSheet(DeleteBranchSheetContent(branchName: "onboarding", pullRequestNumber: 142), onDelete: {}, onViewPullRequest: {}),
            named: "delete-pullRequest", area: area
        )
    }
}

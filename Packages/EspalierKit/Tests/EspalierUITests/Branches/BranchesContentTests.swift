// What the Branches section, the branch picker, and the branch sheets show,
// from their content values.

import AppKit
import EspalierCore
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A local branch.
func localBranch(_ name: String, sha: String = "1111111111111111111111111111111111111111", upstream: String? = nil) -> Branch {
    Branch(name: name, upstream: upstream, tip: BranchTip(sha: sha), type: .local, ref: "refs/heads/\(name)")
}

/// A remote branch (`origin/feature`).
func remoteBranch(_ name: String, sha: String = "2222222222222222222222222222222222222222") -> Branch {
    Branch(name: name, upstream: nil, tip: BranchTip(sha: sha), type: .remote, ref: "refs/remotes/\(name)")
}

/// An open pull request from `head` in `repository`.
func pullRequest(_ number: Int, head: String, in repository: GitHubRepository, draft: Bool = false) -> PullRequest {
    PullRequest(
        created: UIFixtures.now,
        title: "Pull request \(number)",
        pullRequestNumber: number,
        head: PullRequestRef(ref: head, sha: "3333333333333333333333333333333333333333", gitHubRepository: repository),
        base: PullRequestRef(ref: "main", sha: "4444444444444444444444444444444444444444", gitHubRepository: repository),
        author: "octocat",
        draft: draft,
        body: ""
    )
}

@Suite("Branches content") @MainActor
struct BranchesContentTests {
    // MARK: The section

    @Test("the current branch, the default, recent, other in folders, then remotes")
    func order() throws {
        let main = localBranch("main", upstream: "origin/main")
        let current = localBranch("feature/login", upstream: "origin/feature/login")
        let recent = localBranch("fix/crash")
        let others = [localBranch("zeta"), localBranch("feature/signup"), localBranch("alpha"), localBranch("feature/ui/colors")]
        let remotes = [remoteBranch("origin/experiment"), remoteBranch("upstream/release/1.0"), remoteBranch("espalier-octocat/main")]
        let content = BranchesSectionContent.make(.init(
            branches: [main, current, recent] + others + remotes,
            tip: .valid(branch: current),
            defaultBranch: main,
            recentBranches: [current, recent, main]
        ))

        #expect(content.current?.name == "feature/login")
        #expect(content.current?.isCurrent == true)
        #expect(content.defaultBranch?.name == "main")
        #expect(content.recent.map(\.name) == ["fix/crash"])
        // Folders first, each by name, then branches by name; titles are
        // the names' last components.
        #expect(content.other.map(\.id) == ["folder:other:feature", "refs/heads/alpha", "refs/heads/zeta"])
        guard case .folder(let feature) = content.other[0] else {
            Issue.record("No feature folder")
            return
        }
        #expect(feature.children.map(\.id) == ["folder:other:feature/ui", "refs/heads/feature/signup"])
        guard case .branch(let signup) = feature.children[1] else {
            Issue.record("No signup branch")
            return
        }
        #expect(signup.title == "signup")
        #expect(signup.name == "feature/signup")
        #expect(content.otherCount == 4)
        // Remote branches by remote, without Espalier's fork remotes'.
        #expect(content.remotes.map(\.name) == ["origin", "upstream"])
        #expect(content.remotes[1].nodes.map(\.id) == ["folder:remote/upstream:release"])
        #expect(content.remoteCount == 2)
        #expect(content.allRows.map(\.name) == [
            "feature/login", "main", "fix/crash", "feature/ui/colors", "feature/signup", "alpha", "zeta",
            "origin/experiment", "upstream/release/1.0",
        ])
    }

    @Test("canonically equivalent folder names share a folder, named as first seen; a remote branch outside refs/remotes is under “remote”")
    func folders() throws {
        let main = localBranch("main")
        let odd = Branch(name: "odd/one", upstream: nil, tip: BranchTip(sha: "2222222222222222222222222222222222222222"), type: .remote, ref: "refs/odd/one")
        let content = BranchesSectionContent.make(.init(
            branches: [main, localBranch("caf\u{E9}/menu"), localBranch("cafe\u{301}/drinks"), localBranch("Caf\u{E9}/desserts"), odd],
            tip: .valid(branch: main)
        ))
        // "café" (NFC) and "café" (NFD) share a folder; "Café" has its own.
        let folders = content.other.compactMap { node -> BranchFolder? in
            if case .folder(let folder) = node { folder } else { nil }
        }
        #expect(folders.count == 2)
        let shared = try #require(folders.first { $0.children.count == 2 })
        #expect(Array(shared.name.unicodeScalars) == Array("caf\u{E9}".unicodeScalars))
        #expect(shared.children.map(\.id) == ["refs/heads/cafe\u{301}/drinks", "refs/heads/caf\u{E9}/menu"])
        let capitalized = try #require(folders.first { $0.children.count == 1 })
        #expect(Array(capitalized.name.unicodeScalars) == Array("Caf\u{E9}".unicodeScalars))
        #expect(content.remotes.map(\.name) == ["remote"])
        #expect(content.remotes.first?.nodes.map(\.id) == ["refs/odd/one"])
    }

    @Test("a detached HEAD and an unborn branch")
    func headStates() {
        let main = localBranch("main")
        let detached = BranchesSectionContent.make(.init(branches: [main], tip: .detached(currentSha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"), defaultBranch: main))
        #expect(detached.detachedSHA == "a1b2c3d")
        #expect(detached.current == nil)
        #expect(detached.defaultBranch?.name == "main")

        let unborn = BranchesSectionContent.make(.init(branches: [], tip: .unborn(ref: "main")))
        #expect(unborn.unbornBranch == "main")
        #expect(!unborn.isEmpty)
        #expect(BranchesSectionContent.make(.init(branches: [], tip: .unknown)).isEmpty)
    }

    @Test("the filter narrows every group and opens the folders")
    func filter() {
        let main = localBranch("main")
        let content = BranchesSectionContent.make(.init(
            branches: [main, localBranch("feature/login"), localBranch("feature/signup"), remoteBranch("origin/login-redesign")],
            tip: .valid(branch: main),
            defaultBranch: main,
            filter: "LOGIN "
        ))
        #expect(content.isFiltering)
        #expect(content.current == nil)
        #expect(content.allRows.map(\.name) == ["feature/login", "origin/login-redesign"])

        // A filter nothing matches leaves no rows; the section still shows
        // while filtering.
        let none = BranchesSectionContent.make(.init(branches: [main, localBranch("feature/login")], tip: .valid(branch: main), defaultBranch: main, filter: "nothing"))
        #expect(none.isFiltering)
        #expect(none.isEmpty)
        #expect(none.allRows.isEmpty)
    }

    @Test("while commits are dragged, the section's rows start with New Branch…")
    func newBranchDropRow() throws {
        let main = localBranch("main")
        let content = BranchesSectionContent.make(.init(branches: [main, localBranch("feature/login")], tip: .valid(branch: main), defaultBranch: main))
        /// The rows the sidebar's table shows, and the window it's in.
        func rows(showsNewBranchDropRow: Bool) throws -> (count: Int, window: NSWindow) {
            let size = CGSize(width: 240, height: 200)
            let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: Snapshot.deterministic(
                List {
                    BranchesSectionRows(content: content, showsNewBranchDropRow: showsNewBranchDropRow)
                }
                .sidebarListStyle()
            ))
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let table = try #require(Self.firstSubview(NSTableView.self, in: host))
            return (table.numberOfRows, window)
        }
        let without = try rows(showsNewBranchDropRow: false)
        defer { without.window.contentView = nil }
        let with = try rows(showsNewBranchDropRow: true)
        defer { with.window.contentView = nil }
        // The current branch, then the default branch's row.
        #expect(without.count == 2)
        #expect(with.count == without.count + 1)
    }

    /// The first view of `type` in `view`'s hierarchy.
    private static func firstSubview<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(type, in: subview) {
                return match
            }
        }
        return nil
    }

    @Test("rows compare with their upstreams")
    func tracking() {
        let current = localBranch("main", upstream: "origin/main")
        let content = BranchesSectionContent.make(.init(
            branches: [
                current,
                localBranch("ahead", upstream: "origin/ahead"),
                localBranch("gone", upstream: "origin/gone"),
                localBranch("unpublished"),
                localBranch("loading", upstream: "origin/loading"),
                remoteBranch("origin/remote-only"),
            ],
            tip: .valid(branch: current),
            currentAheadBehind: AheadBehind(ahead: 2, behind: 3),
            upstreamStates: [
                "refs/heads/main": .tracking(AheadBehind(ahead: 0, behind: 0)),
                "refs/heads/ahead": .tracking(AheadBehind(ahead: 4, behind: 0)),
                "refs/heads/gone": .gone,
            ]
        ))
        let tracking = Dictionary(uniqueKeysWithValues: content.allRows.map { ($0.name, $0.tracking) })
        // The current branch's comes from the status.
        #expect(tracking["main"] == .aheadBehind(ahead: 2, behind: 3))
        #expect(tracking["ahead"] == .aheadBehind(ahead: 4, behind: 0))
        #expect(tracking["gone"] == .upstreamGone)
        #expect(tracking["unpublished"] == .notPublished)
        #expect(tracking["loading"] == BranchTracking.none)
        #expect(tracking["origin/remote-only"] == BranchTracking.none)

        #expect(BranchTracking.aheadBehind(ahead: 2, behind: 3).countsText == "↑2 ↓3")
        #expect(BranchTracking.aheadBehind(ahead: 0, behind: 3).countsText == "↓3")
        #expect(BranchTracking.aheadBehind(ahead: 0, behind: 0).countsText == nil)
        #expect(BranchTracking.aheadBehind(ahead: 1_234, behind: 12_500).countsText == "↑1.2k ↓12k")
        #expect(BranchTracking.aheadBehind(ahead: 1, behind: 2).description == "1 commit ahead, 2 commits behind")
        #expect(BranchTracking.notPublished.description == "Not published")
    }

    @Test("pull requests show on their branches, with their checks")
    func pullRequests() {
        let repository = gitHubRepoFixture(owner: "octo-org", name: "website")
        let fork = gitHubRepoFixture(owner: "someone", name: "website")
        let main = localBranch("main", upstream: "origin/main")
        let feature = localBranch("feature", upstream: "origin/feature")
        let draft = localBranch("draft", upstream: "origin/draft")
        let elsewhere = localBranch("elsewhere", upstream: "origin/elsewhere")
        let content = BranchesSectionContent.make(.init(
            branches: [main, feature, draft, elsewhere, remoteBranch("origin/theirs")],
            tip: .valid(branch: main),
            pullRequests: [
                pullRequest(142, head: "feature", in: repository),
                pullRequest(143, head: "draft", in: repository, draft: true),
                pullRequest(144, head: "elsewhere", in: fork),
                pullRequest(145, head: "theirs", in: repository),
            ],
            checks: [142: .failure],
            remotes: [Remote(name: "origin", url: "https://github.com/octo-org/website.git")]
        ))
        let badges = Dictionary(uniqueKeysWithValues: content.allRows.map { ($0.name, $0.pullRequest) })
        #expect(badges["feature"] == BranchPullRequestBadge(number: 142, isDraft: false, checks: .failure))
        #expect(badges["draft"] == BranchPullRequestBadge(number: 143, isDraft: true))
        // The pull request's head is in another repository.
        #expect(badges["elsewhere"] == .some(nil))
        #expect(badges["origin/theirs"] == BranchPullRequestBadge(number: 145, isDraft: false))
        #expect(badges["main"] == .some(nil))
        #expect(BranchPullRequestBadge(number: 142, isDraft: false, checks: .success).tooltip == "Pull request #142 · Checks: Successful")
        #expect(BranchPullRequestBadge(number: 7, isDraft: true).tooltip == "Draft pull request #7")
    }

    @Test("Restore Pruned Branch names the day a branch was deleted, or today")
    func prunedTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = UIFixtures.timeZone
        calendar.locale = Locale(identifier: "en_US")
        let today = PrunedBranch(name: "old-feature", sha: "abc", date: UIFixtures.minutesAgo(30))
        #expect(RestorePrunedBranchMenu.title(of: today, now: UIFixtures.now, calendar: calendar) == "old-feature (deleted today)")
        let earlier = PrunedBranch(name: "older-feature", sha: "def", date: UIFixtures.minutesAgo(3 * 24 * 60))
        #expect(RestorePrunedBranchMenu.title(of: earlier, now: UIFixtures.now, calendar: calendar) == "older-feature (deleted Oct 3, 2026)")
        // The day is the calendar's: 01:00 UTC is still the day before in
        // San Francisco.
        let early = PrunedBranch(name: "early", sha: "abc", date: UIFixtures.minutesAgo(9 * 60))
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(RestorePrunedBranchMenu.title(of: early, now: UIFixtures.now, calendar: calendar) == "early (deleted Oct 5, 2026)")
    }

    // MARK: The picker

    @Test("the picker groups as desktop: default, recent, other, then remote")
    func pickerGroups() {
        let main = localBranch("main")
        let recent = localBranch("recent")
        let content = BranchPickerContent.make(
            branches: [main, recent, localBranch("other"), remoteBranch("origin/remote"), remoteBranch("espalier-fork/x")],
            defaultBranch: main,
            recentBranches: [recent],
            includesRemoteBranches: true,
            filter: ""
        )
        #expect(content.groups.map(\.title) == ["Default Branch", "Recent Branches", "Other Branches", "Remote Branches"])
        #expect(content.branches.map(\.name) == ["main", "recent", "other", "origin/remote"])

        let local = BranchPickerContent.make(
            branches: [main, localBranch("other"), remoteBranch("origin/remote")],
            defaultBranch: main,
            recentBranches: [],
            includesRemoteBranches: false,
            filter: ""
        )
        #expect(local.groups.map(\.title) == ["Default Branch", "Other Branches"])
    }

    @Test("the picker's filter keeps groups and ranks matches")
    func pickerFilter() {
        let branches = ["zz-login", "login", "feature/login-form", "logout", "alien-ogre"].map { localBranch($0) }
        let content = BranchPickerContent.make(branches: branches, defaultBranch: nil, recentBranches: [], includesRemoteBranches: true, filter: "log")
        // Prefix, then after a separator, then anywhere, then in order.
        #expect(content.branches.map(\.name) == ["login", "logout", "zz-login", "feature/login-form", "alien-ogre"])
        #expect(BranchFilter.score("Feature", "fea") == 4)
        #expect(BranchFilter.score("fix/crash", "crash") == 3)
        #expect(BranchFilter.score("hotfix", "fix") == 2)
        #expect(BranchFilter.score("feature/login", "ftl") == 1)
        #expect(BranchFilter.score("main", "x") == nil)

        let none = BranchPickerContent.make(branches: branches, defaultBranch: nil, recentBranches: [], includesRemoteBranches: true, filter: "qq")
        #expect(none.isEmpty)
        #expect(none.filter == "qq")
    }

    @Test("the picker can list only some branches, grouped as usual")
    func pickerCandidates() {
        let main = localBranch("main", upstream: "origin/main")
        let recent = localBranch("recent", upstream: "upstream/recent")
        let other = localBranch("other", upstream: "origin/other")
        let release = remoteBranch("origin/release")
        let upstreamMain = remoteBranch("upstream/main")
        let all = [main, recent, other, release, upstreamMain]
        func make(filter: String = "", candidates: [Branch]?) -> BranchPickerContent {
            BranchPickerContent.make(branches: all, defaultBranch: main, recentBranches: [recent, other], includesRemoteBranches: true, filter: filter, candidates: candidates)
        }
        // A pull request's possible bases on origin: its branches, and the
        // local branches tracking them.
        let onOrigin = [main, other, release]
        let content = make(candidates: onOrigin)
        #expect(content.groups.map(\.title) == ["Default Branch", "Recent Branches", "Remote Branches"])
        #expect(content.branches.map(\.name) == ["main", "other", "origin/release"])
        // The default and recent branches show only when they're candidates.
        let upstreamOnly = make(candidates: [upstreamMain, recent])
        #expect(upstreamOnly.groups.map(\.title) == ["Recent Branches", "Remote Branches"])
        #expect(upstreamOnly.branches.map(\.name) == ["recent", "upstream/main"])
        #expect(make(filter: "rel", candidates: onOrigin).branches.map(\.name) == ["origin/release"])
        #expect(make(candidates: []).isEmpty)
        #expect(make(candidates: nil).branches.map(\.name) == ["main", "recent", "other", "origin/release", "upstream/main"])
    }

    // MARK: Names

    @Test("names are sanitized and checked as desktop's dialogs do")
    func names() {
        let branches = [localBranch("main"), localBranch("feature"), remoteBranch("origin/shared")]
        #expect(BranchNameValidation.validate("", branches: branches) == BranchNameValidation(sanitizedName: "", messages: []))
        #expect(!BranchNameValidation.validate("", branches: branches).isValid)

        let spaced = BranchNameValidation.validate("my new branch", branches: branches)
        #expect(spaced.sanitizedName == "my-new-branch")
        #expect(spaced.messages == [.warning("Will be created as my-new-branch.")])
        #expect(spaced.isValid)

        #expect(BranchNameValidation.validate("..", branches: branches).messages == [.error(".. is not a valid name.")])
        #expect(BranchNameValidation.validate("feature", branches: branches).messages == [.error("A branch named feature already exists.")])
        #expect(!BranchNameValidation.validate("feature", branches: branches).isValid)
        #expect(BranchNameValidation.validate("shared", branches: branches).messages == [.warning("A branch named shared already exists on the remote.")])

        // A rename may keep the name, and says "saved".
        let rename = BranchNameValidation.validate("feature", branches: branches, verb: "saved", currentName: "feature")
        #expect(rename.isValid)
        #expect(BranchNameValidation.validate("a b", branches: branches, verb: "saved", currentName: "feature").messages == [.warning("Will be saved as a-b.")])

        // The rules' answer.
        let restricted = BranchNameValidation.validate("release", branches: branches)
            .adding(BranchNameRuleError(message: "Repository rules don't allow a branch named “release”.", isWarning: false))
        #expect(!restricted.isValid)
        let bypass = BranchNameValidation.validate("release", branches: branches)
            .adding(BranchNameRuleError(message: "Repository rules restrict a branch named “release”, but you can bypass them.", isWarning: true))
        #expect(bypass.isValid)
        #expect(BranchNameRuleCheck.applying(BranchNameRuleCheck(name: "other", error: BranchNameRuleError(message: "No", isWarning: false)), to: bypass) == bypass)
    }

    // MARK: Sheets

    @Test("New Branch offers the default branch or the current one")
    func newBranchChoices() {
        let main = localBranch("main")
        let feature = localBranch("feature")
        let choice = NewBranchSheetContent.make(mode: .create, tip: .valid(branch: feature), defaultBranch: main, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(choice.title == "Create a Branch")
        #expect(choice.confirmButton == "Create Branch")
        guard case .choice(let options) = choice.base else {
            Issue.record("No choice")
            return
        }
        #expect(options.map(\.title) == ["main", "feature"])
        #expect(options.map(\.startPoint) == [.defaultBranch, .currentBranch])
        #expect(options[0].description == "The default branch in your repository. Pick this to start on something new that's not dependent on your current branch.")
        #expect(choice.initialStartPoint == .defaultBranch)
        #expect(choice.baseExplanation == nil)

        let onDefault = NewBranchSheetContent.make(mode: .create, tip: .valid(branch: main), defaultBranch: main, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(onDefault.baseExplanation == "Your new branch will be based on your currently checked out branch (main). main is the default branch for your repository.")
        #expect(onDefault.initialStartPoint == .defaultBranch)

        let noDefault = NewBranchSheetContent.make(mode: .create, tip: .valid(branch: feature), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(noDefault.baseExplanation == "Your new branch will be based on your currently checked out branch (feature).")
    }

    @Test("New Branch explains a detached HEAD, an unborn branch, a commit, and a fork")
    func newBranchExplanations() {
        let detached = NewBranchSheetContent.make(mode: .create, tip: .detached(currentSha: "a1b2c3d4e5f6"), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(detached.baseExplanation == "You're on a detached HEAD, not a branch, so your new branch will be based on the checked-out commit (a1b2c3d).")
        #expect(detached.initialStartPoint == .head)

        let unborn = NewBranchSheetContent.make(mode: .create, tip: .unborn(ref: "main"), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(unborn.baseExplanation == "Your current branch has no commits yet, so creating a new branch renames it.")

        let commit = NewBranchSheetContent.make(
            mode: .startPoint("a1b2c3d4e5f6", summary: "Fix the crash"),
            tip: .valid(branch: localBranch("main")), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false
        )
        #expect(commit.baseExplanation == "Your new branch will be based on the commit 'Fix the crash' (a1b2c3d) from your repository.")
        let tag = NewBranchSheetContent.make(mode: .startPoint("v1.0", summary: nil), tip: .valid(branch: localBranch("main")), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(tag.baseExplanation == "Your new branch will be based on v1.0.")

        let upstreamMain = remoteBranch("upstream/main")
        let fork = NewBranchSheetContent.make(mode: .create, tip: .valid(branch: localBranch("feature")), defaultBranch: localBranch("main"), upstreamDefaultBranch: upstreamMain, upstreamRepositoryName: "octo-org/website", isFork: true)
        guard case .choice(let options) = fork.base else {
            Issue.record("No choice")
            return
        }
        #expect(options.map(\.startPoint) == [.upstreamDefaultBranch, .currentBranch])
        #expect(options[0].title == "upstream/main")
        #expect(fork.initialStartPoint == .upstreamDefaultBranch)
        #expect(fork.showsForkBehaviorLink)
        let onUpstreamDefault = NewBranchSheetContent.make(mode: .create, tip: .valid(branch: localBranch("main")), defaultBranch: localBranch("main"), upstreamDefaultBranch: upstreamMain, upstreamRepositoryName: "octo-org/website", isFork: true)
        #expect(onUpstreamDefault.baseExplanation == "Your new branch will be based on octo-org/website's default branch (main).")

        let cherryPick = NewBranchSheetContent.make(mode: .cherryPick(shas: ["a"]), tip: .valid(branch: localBranch("main")), defaultBranch: nil, upstreamDefaultBranch: nil, upstreamRepositoryName: nil, isFork: false)
        #expect(cherryPick.title == "Cherry-pick to New Branch")
        #expect(cherryPick.confirmButton == "Create Branch and Cherry-pick")
    }

    @Test("Rename warns that the remote keeps its name only for a branch that tracks one")
    func renameWarning() {
        #expect(RenameBranchSheetContent(branchName: "spike", upstream: nil).remoteWarning == nil)
        let tracking = RenameBranchSheetContent(branchName: "feature/login", upstream: "origin/feature/login")
        #expect(tracking.remoteWarning?.contains("origin/feature/login") == true)
    }

    // MARK: Drops

    @Test("dropped commits cherry-pick to a branch, or open the New Branch sheet; refused drops do nothing")
    func drops() {
        let id = UIFixtures.repositoryID
        let payload = CommitDragPayload(repositoryID: id, shas: ["a", "b"])
        #expect(CommitDropDecision.make([payload], on: .branch(name: "feature", isCurrent: false), repository: id, isBusy: false)
            == .cherryPick(shas: ["a", "b"], branch: "feature"))
        #expect(CommitDropDecision.make([payload], on: .newBranch, repository: id, isBusy: false) == .cherryPickToNewBranch(shas: ["a", "b"]))
        #expect(CommitDropDecision.make([payload], on: .branch(name: "main", isCurrent: true), repository: id, isBusy: false) == .refused)
        #expect(CommitDropDecision.make([payload], on: .branch(name: "feature", isCurrent: false), repository: id, isBusy: true) == .refused)
        #expect(CommitDropDecision.make([payload], on: .branch(name: "feature", isCurrent: false), repository: RepositoryID(), isBusy: false) == .refused)
        #expect(CommitDropDecision.make([CommitDragPayload(repositoryID: id, shas: [])], on: .newBranch, repository: id, isBusy: false) == .refused)
        #expect(CommitDropDecision.make([payload], on: .newBranch, repository: nil, isBusy: false) == .refused)
        #expect(!CommitDropDecision.accepts(.branch(name: "main", isCurrent: true), isBusy: false))
        #expect(!CommitDropDecision.accepts(.newBranch, isBusy: true))
        #expect(CommitDropDecision.accepts(.newBranch, isBusy: false))
        #expect(CommitDropTarget.branch(name: "feature", isCurrent: false).actionTitle == "Cherry-pick to feature")
    }
}

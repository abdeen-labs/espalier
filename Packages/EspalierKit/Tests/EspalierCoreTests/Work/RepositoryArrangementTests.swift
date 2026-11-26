// The arranged list from plain values: the pinned section, the two
// arrangements and their order, what's unseen, the Needs You reasons, and
// the worktree rows.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The start of a minute.
private let minute = Date(timeIntervalSince1970: 1_700_000_040)

/// A repository titled `title`.
private func record(_ title: String) -> RepositoryRecord {
    ModelFixtures.record(path: "/repositories/\(title)")
}

/// The key of the worktree a record points at.
private func key(_ record: RepositoryRecord) -> WorktreeKey {
    WorktreeKey(repositoryID: record.id, path: record.path)
}

/// Every Needs You reason counting.
private let everyReason = RepositoryArrangementSettings(arrangement: .needsYou, needsYouReasons: Set(NeedsYouReason.allCases))

/// A clean status on a branch that's level with its upstream.
private let onBranchWithUpstream = RepositoryIndicator(
    head: .branch(name: "feature"),
    aheadBehind: AheadBehind(ahead: 0, behind: 0),
    changedFilesCount: 0
)

private func arrange(
    _ records: [RepositoryRecord],
    indicators: [RepositoryID: RepositoryIndicator] = [:],
    worktrees: [RepositoryID: [WorktreeSummary]] = [:],
    pullRequests: [RepositoryID: RepositoryPullRequestFacts] = [:],
    activity: [WorktreeKey: WorktreeActivity] = [:],
    open: WorktreeKey? = nil,
    pinned: [RepositoryID] = [],
    settings: RepositoryArrangementSettings = RepositoryArrangementSettings()
) -> [ArrangedRepositorySection] {
    arrangeRepositories(
        records,
        indicators: indicators,
        worktrees: worktrees,
        pullRequests: pullRequests,
        activity: activity,
        openWorktree: open,
        pinned: pinned,
        settings: settings
    )
}

extension [ArrangedRepositorySection] {
    /// The sections' kinds, in order.
    fileprivate var kinds: [ArrangedRepositorySection.Kind] {
        map(\.kind)
    }

    /// The titles of a section's repositories, in order; none without the
    /// section.
    fileprivate func titles(_ kind: ArrangedRepositorySection.Kind) -> [String] {
        first { $0.kind == kind }?.repositories.map(\.title) ?? []
    }

    /// The row of the repository titled `title`.
    fileprivate func row(_ title: String) throws -> ArrangedRepository {
        try #require(flatMap(\.repositories).first { $0.title == title })
    }
}

@Suite("Repository arrangement")
struct RepositoryArrangementTests {
    @Test("Recent Activity is one section: the latest activity first, then the repositories with none, by title")
    func recentActivity() throws {
        let (charlie, alpha, bravo, delta) = (record("charlie"), record("Alpha"), record("bravo"), record("delta"))
        let sections = arrange([charlie, alpha, bravo, delta], activity: [
            key(delta): WorktreeActivity(files: minute.addingTimeInterval(300)),
            key(bravo): WorktreeActivity(files: minute, head: minute.addingTimeInterval(600)),
        ])

        #expect(sections.kinds == [.recentActivity])
        #expect(sections.titles(.recentActivity) == ["bravo", "delta", "Alpha", "charlie"])
        #expect(try sections.row("bravo").latestActivity == minute.addingTimeInterval(600))
        #expect(try sections.row("Alpha").latestActivity == nil)
    }

    @Test("repositories active in the same minute are in order of their titles, whichever was last")
    func activityByTheMinute() {
        let (alpha, bravo, charlie) = (record("alpha"), record("bravo"), record("charlie"))
        func titles(alphaAt: TimeInterval, bravoAt: TimeInterval, charlieAt: TimeInterval) -> [String] {
            arrange([charlie, bravo, alpha], activity: [
                key(alpha): WorktreeActivity(files: minute.addingTimeInterval(alphaAt)),
                key(bravo): WorktreeActivity(files: minute.addingTimeInterval(bravoAt)),
                key(charlie): WorktreeActivity(files: minute.addingTimeInterval(charlieAt)),
            ]).titles(.recentActivity)
        }

        // All three busy in one minute, each the latest in turn.
        #expect(titles(alphaAt: 10, bravoAt: 20, charlieAt: 30) == ["alpha", "bravo", "charlie"])
        #expect(titles(alphaAt: 40, bravoAt: 20, charlieAt: 30) == ["alpha", "bravo", "charlie"])
        #expect(titles(alphaAt: 40, bravoAt: 59.9, charlieAt: 30) == ["alpha", "bravo", "charlie"])
        // The next minute's activity comes first.
        #expect(titles(alphaAt: 40, bravoAt: 59.9, charlieAt: 60) == ["charlie", "alpha", "bravo"])
    }

    @Test("only the kinds of activity that count order the list and make a worktree unseen")
    func countedKinds() throws {
        let (alpha, bravo) = (record("alpha"), record("bravo"))
        let activity = [
            key(alpha): WorktreeActivity(files: minute),
            key(bravo): WorktreeActivity(pullRequest: minute.addingTimeInterval(600)),
        ]

        // Pull requests don't count by default.
        let byDefault = arrange([alpha, bravo], activity: activity)
        #expect(byDefault.titles(.recentActivity) == ["alpha", "bravo"])
        #expect(try byDefault.row("bravo").latestActivity == nil)
        #expect(try !byDefault.row("bravo").isUnseen)
        #expect(try byDefault.row("alpha").isUnseen)

        let pullRequestsOnly = arrange([alpha, bravo], activity: activity, settings: RepositoryArrangementSettings(activityKinds: [.pullRequest]))
        #expect(pullRequestsOnly.titles(.recentActivity) == ["bravo", "alpha"])
        #expect(try pullRequestsOnly.row("bravo").isUnseen)
        #expect(try !pullRequestsOnly.row("alpha").isUnseen)
        #expect(try pullRequestsOnly.row("alpha").latestActivity == nil)
    }

    @Test("pinned repositories come first, in the order they were pinned, and aren't repeated below", arguments: RepositoryArrangement.allCases)
    func pinned(_ arrangement: RepositoryArrangement) throws {
        let (alpha, bravo, charlie, delta) = (record("alpha"), record("bravo"), record("charlie"), record("delta"))
        let sections = arrange(
            [alpha, bravo, charlie, delta],
            // Alpha and delta need the user; alpha was active last.
            indicators: [
                alpha.id: RepositoryIndicator(aheadBehind: nil, changedFilesCount: 1),
                delta.id: RepositoryIndicator(aheadBehind: nil, changedFilesCount: 1),
            ],
            activity: [key(alpha): WorktreeActivity(files: minute)],
            pinned: [delta.id, bravo.id],
            settings: RepositoryArrangementSettings(arrangement: arrangement)
        )

        #expect(sections.titles(.pinned) == ["delta", "bravo"])
        #expect(try sections.row("delta").isPinned)
        #expect(try !sections.row("alpha").isPinned)
        switch arrangement {
        case .recentActivity:
            #expect(sections.kinds == [.pinned, .recentActivity])
            #expect(sections.titles(.recentActivity) == ["alpha", "charlie"])
        case .needsYou:
            #expect(sections.kinds == [.pinned, .needsYou, .others])
            #expect(sections.titles(.needsYou) == ["alpha"])
            #expect(sections.titles(.others) == ["charlie"])
        }
    }

    @Test("Needs You: the repositories with a reason that counts, the latest activity first, then the rest by title")
    func needsYou() throws {
        let (alpha, bravo, charlie, delta, echo) = (record("alpha"), record("bravo"), record("charlie"), record("delta"), record("echo"))
        let sections = arrange(
            [echo, delta, charlie, bravo, alpha],
            indicators: [
                alpha.id: RepositoryIndicator(aheadBehind: nil, changedFilesCount: 2),
                bravo.id: RepositoryIndicator(aheadBehind: AheadBehind(ahead: 1, behind: 0), changedFilesCount: 0),
                charlie.id: RepositoryIndicator(aheadBehind: nil, changedFilesCount: 0, stoppedOperation: .rebase, conflictedFilesCount: 1),
                // Commits to pull don't count by default.
                delta.id: RepositoryIndicator(aheadBehind: AheadBehind(ahead: 0, behind: 3), changedFilesCount: 0),
            ],
            activity: [
                key(charlie): WorktreeActivity(head: minute.addingTimeInterval(120)),
                // The latest of all, in a repository that doesn't need the user.
                key(echo): WorktreeActivity(files: minute.addingTimeInterval(900)),
            ],
            settings: RepositoryArrangementSettings(arrangement: .needsYou)
        )

        #expect(sections.kinds == [.needsYou, .others])
        #expect(sections.titles(.needsYou) == ["charlie", "alpha", "bravo"])
        #expect(sections.titles(.others) == ["delta", "echo"])
        #expect(try sections.row("alpha").needsYouReasons == [.uncommittedChanges])
        #expect(try sections.row("bravo").needsYouReasons == [.commitsToPush])
        #expect(try sections.row("charlie").needsYouReasons == [.stoppedOperation])
        #expect(try sections.row("delta").needsYouReasons.isEmpty)
    }

    @Test("a reason that's turned off puts no repository under Needs You, and one that's turned on does")
    func countedReasons() throws {
        let (alpha, bravo) = (record("alpha"), record("bravo"))
        let indicators = [
            alpha.id: RepositoryIndicator(aheadBehind: nil, changedFilesCount: 2),
            bravo.id: RepositoryIndicator(aheadBehind: AheadBehind(ahead: 0, behind: 3), changedFilesCount: 0),
        ]
        let sections = arrange(
            [alpha, bravo],
            indicators: indicators,
            settings: RepositoryArrangementSettings(arrangement: .needsYou, needsYouReasons: [.commitsToPull])
        )

        #expect(sections.titles(.needsYou) == ["bravo"])
        #expect(sections.titles(.others) == ["alpha"])
        #expect(try sections.row("alpha").needsYouReasons.isEmpty)
        #expect(try sections.row("bravo").needsYouReasons == [.commitsToPull])
    }

    @Test("a repository's reasons come from its status and its pull request", arguments: [
        NamedCase("none for a clean branch level with its upstream", (onBranchWithUpstream, nil, [])),
        NamedCase("uncommitted changes", (RepositoryIndicator(aheadBehind: nil, changedFilesCount: 1), nil, [.uncommittedChanges])),
        NamedCase("commits to push and to pull", (RepositoryIndicator(aheadBehind: AheadBehind(ahead: 2, behind: 1), changedFilesCount: 0), nil, [.commitsToPush, .commitsToPull])),
        NamedCase("a stopped merge with changes", (
            RepositoryIndicator(aheadBehind: nil, changedFilesCount: 3, stoppedOperation: .merge, conflictedFilesCount: 1), nil,
            [.stoppedOperation, .uncommittedChanges]
        )),
        NamedCase("a pull request whose checks are failing", (
            onBranchWithUpstream, RepositoryPullRequestFacts(hasPullRequest: true, checksFailing: true), [.pullRequestAttention]
        )),
        NamedCase("a pull request with changes requested", (
            onBranchWithUpstream, RepositoryPullRequestFacts(hasPullRequest: true, changesRequested: true), [.pullRequestAttention]
        )),
        NamedCase("none for a pull request that's fine", (onBranchWithUpstream, RepositoryPullRequestFacts(hasPullRequest: true), [])),
        NamedCase("a pushed branch with no pull request", (
            onBranchWithUpstream, RepositoryPullRequestFacts(hasPullRequest: false), [.branchWithoutPullRequest]
        )),
        NamedCase("none for a branch with no pull request that isn't pushed", (
            RepositoryIndicator(head: .branch(name: "feature"), aheadBehind: nil, changedFilesCount: 0),
            RepositoryPullRequestFacts(hasPullRequest: false), []
        )),
        NamedCase("none for a detached HEAD with no pull request", (
            RepositoryIndicator(head: .detached(sha: "abc"), aheadBehind: nil, changedFilesCount: 0),
            RepositoryPullRequestFacts(hasPullRequest: false), []
        )),
        NamedCase("none for a repository whose status hasn't loaded", (nil, nil, [])),
    ] as [NamedCase<(RepositoryIndicator?, RepositoryPullRequestFacts?, Set<NeedsYouReason>)>])
    func reasons(_ testCase: NamedCase<(RepositoryIndicator?, RepositoryPullRequestFacts?, Set<NeedsYouReason>)>) throws {
        let (indicator, pullRequest, expected) = testCase.value
        let repository = record("alpha")
        let sections = arrange(
            [repository],
            indicators: indicator.map { [repository.id: $0] } ?? [:],
            pullRequests: pullRequest.map { [repository.id: $0] } ?? [:],
            settings: everyReason
        )
        #expect(try sections.row("alpha").needsYouReasons == expected)
        #expect(sections.kinds == [expected.isEmpty ? .others : .needsYou])
    }

    @Test("a worktree is unseen with activity later than when it was last open, unless it's open")
    func unseen() throws {
        let (alpha, bravo, charlie) = (record("alpha"), record("bravo"), record("charlie"))
        let activity = [
            // Active after it was last open.
            key(alpha): WorktreeActivity(files: minute.addingTimeInterval(30), lastOpen: minute),
            // Last open after its activity.
            key(bravo): WorktreeActivity(files: minute, lastOpen: minute.addingTimeInterval(30)),
            // Never open.
            key(charlie): WorktreeActivity(head: minute),
        ]

        let sections = arrange([alpha, bravo, charlie], activity: activity)
        #expect(try sections.row("alpha").isUnseen)
        #expect(try !sections.row("bravo").isUnseen)
        #expect(try sections.row("charlie").isUnseen)

        let whileOpen = arrange([alpha, bravo, charlie], activity: activity, open: key(alpha))
        #expect(try !whileOpen.row("alpha").isUnseen)
        #expect(try whileOpen.row("charlie").isUnseen)
    }

    @Test("a repository with no worktrees given has one row: the worktree its record points at, with its indicator")
    func ownWorktree() throws {
        let alpha = record("alpha")
        let indicator = RepositoryIndicator(
            head: .branch(name: "main"),
            aheadBehind: AheadBehind(ahead: 1, behind: 2),
            changedFilesCount: 4,
            stoppedOperation: .cherryPick,
            conflictedFilesCount: 3
        )
        let row = try arrange(
            [alpha],
            indicators: [alpha.id: indicator],
            activity: [key(alpha): WorktreeActivity(head: minute)]
        ).row("alpha")

        #expect(row.head == .branch(name: "main"))
        #expect(row.aheadBehind == AheadBehind(ahead: 1, behind: 2))
        #expect(row.changedFilesCount == 4)
        #expect(row.stoppedOperation == .cherryPick)
        #expect(row.conflictedFilesCount == 3)
        #expect(row.worktrees == [ArrangedWorktree(
            id: key(alpha),
            path: "/repositories/alpha",
            name: "alpha",
            head: .branch(name: "main"),
            aheadBehind: AheadBehind(ahead: 1, behind: 2),
            changedFilesCount: 4,
            stoppedOperation: .cherryPick,
            conflictedFilesCount: 3,
            isCurrent: true,
            isUnseen: true,
            latestActivity: minute,
            entry: nil
        )])
    }

    @Test("a repository's activity, unseen mark, and reasons cover all its worktrees")
    func everyWorktree() throws {
        let alpha = record("alpha")
        let bravo = record("bravo")
        let agent = WorktreeKey(repositoryID: alpha.id, path: "/worktrees/alpha-agent")
        let sections = arrange(
            [alpha, bravo],
            indicators: [alpha.id: RepositoryIndicator(head: .branch(name: "main"), aheadBehind: nil, changedFilesCount: 0)],
            worktrees: [alpha.id: [
                WorktreeSummary(path: "/repositories/alpha/", name: "alpha"),
                WorktreeSummary(
                    path: "/worktrees/alpha-agent",
                    name: "alpha-agent",
                    indicator: RepositoryIndicator(head: .branch(name: "agent"), aheadBehind: nil, changedFilesCount: 5)
                ),
            ]],
            activity: [
                key(alpha): WorktreeActivity(head: minute, lastOpen: minute),
                agent: WorktreeActivity(files: minute.addingTimeInterval(240)),
                key(bravo): WorktreeActivity(files: minute.addingTimeInterval(120)),
            ],
            // The repository is selected, at its main worktree.
            open: key(alpha),
            settings: RepositoryArrangementSettings(arrangement: .needsYou)
        )

        let row = try sections.row("alpha")
        // Its own status is clean and seen; the other worktree's isn't.
        #expect(row.changedFilesCount == 0)
        #expect(row.needsYouReasons == [.uncommittedChanges])
        #expect(row.isUnseen)
        #expect(row.latestActivity == minute.addingTimeInterval(240))
        #expect(sections.titles(.needsYou) == ["alpha"])

        #expect(row.worktrees.map(\.name) == ["alpha", "alpha-agent"])
        #expect(row.worktrees.map(\.isCurrent) == [true, false])
        #expect(row.worktrees.map(\.isUnseen) == [false, true])
        #expect(row.worktrees.map(\.latestActivity) == [minute, minute.addingTimeInterval(240)])
        // The worktree the record points at shows the repository's indicator.
        #expect(row.worktrees.map(\.head) == [.branch(name: "main"), .branch(name: "agent")])
        #expect(row.worktrees.map(\.changedFilesCount) == [0, 5])
    }

    @Test("repositories with the same title need disambiguation")
    func disambiguation() throws {
        let first = ModelFixtures.record(path: "/work/app")
        let second = ModelFixtures.record(path: "/personal/app")
        let aliased = ModelFixtures.record(path: "/other/thing", alias: "app")
        let other = ModelFixtures.record(path: "/work/tool")

        let rows = arrange([first, second, aliased, other]).flatMap(\.repositories)
        #expect(rows.map(\.title) == ["app", "app", "app", "tool"])
        // Repositories with the same title stay in the list's order.
        #expect(rows.map(\.id) == [first.id, second.id, aliased.id, other.id])
        #expect(rows.map(\.needsDisambiguation) == [true, true, true, false])
    }
}

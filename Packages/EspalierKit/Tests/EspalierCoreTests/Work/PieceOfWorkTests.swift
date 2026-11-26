// The pieces of work from plain values: each Needs You reason and its
// setting, merged and ready to clean up, the phase rules and the 10-minute
// boundary, the headline's priority, what's unseen, and which worktrees are
// pieces of work.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The time the phases are told at.
private let now = Date(timeIntervalSince1970: 1_700_000_040)

/// The merged pull request's head commit, and the tip of a branch that
/// hasn't moved since.
private let mergedTip = "1111111111111111111111111111111111111111"

/// Every Needs You reason counting.
private let everyReason = WorkSettings(needsYouReasons: Set(NeedsYouReason.allCases))

/// A status on `feature`: `changed` changed files, `ahead`/`behind` its
/// upstream (none with `ahead` nil), and a stopped operation.
private func status(
    changed: Int = 0,
    ahead: Int? = nil,
    behind: Int = 0,
    stopped: RepositoryIndicator.StoppedOperation? = nil,
    conflicted: Int = 0,
    head: RepositoryIndicator.Head = .branch(name: "feature")
) -> RepositoryIndicator {
    RepositoryIndicator(
        head: head,
        aheadBehind: ahead.map { AheadBehind(ahead: $0, behind: behind) },
        changedFilesCount: changed,
        stoppedOperation: stopped,
        conflictedFilesCount: conflicted
    )
}

private func openPullRequest(checks: BranchPullRequest.Checks = .none, review: BranchPullRequest.Review = .none) -> BranchPullRequest {
    BranchPullRequest(
        number: 7,
        title: "Add charts",
        url: URL(string: "https://github.com/octocat/harbor/pull/7")!,
        isDraft: false,
        checks: checks,
        review: review,
        updatedAt: now
    )
}

private let mergedPullRequest = MergedPullRequest(
    number: 8,
    title: "Add charts",
    url: URL(string: "https://github.com/octocat/harbor/pull/8")!,
    headSHA: mergedTip,
    baseBranch: "main",
    mergedAt: now
)

/// What one worktree is, for a test's arguments.
struct WorktreeCase: Sendable {
    var status: RepositoryIndicator?
    var pullRequest: BranchPullRequestStatus?
    var tip: String? = mergedTip
    /// How long before `now` it last changed; nil when that isn't known.
    var changedAgo: TimeInterval?
}

/// The one piece of work of a repository whose record points at a worktree
/// that is `worktree`.
private func piece(_ worktree: WorktreeCase, settings: WorkSettings = WorkSettings()) throws -> PieceOfWork {
    let record = ModelFixtures.record(path: "/repositories/harbor")
    let key = WorktreeKey(repositoryID: record.id, path: record.path)
    let work = makePiecesOfWork(WorkInputs(
        repositories: [record],
        worktrees: [record.id: [WorktreeFacts(
            path: record.path,
            isCurrent: true,
            indicator: worktree.status,
            tip: worktree.tip,
            pullRequest: worktree.pullRequest
        )]],
        lastChanged: worktree.changedAgo.map { [key: now.addingTimeInterval(-$0)] } ?? [:],
        settings: settings,
        now: now
    ))
    return try #require(work.first)
}

@Suite("Pieces of work")
struct PieceOfWorkTests {
    // MARK: Reasons

    @Test("each reason holds when its facts do, and counts only while its setting is on", arguments: [
        NamedCase("uncommitted changes", (WorktreeCase(status: status(changed: 2)), NeedsYouReason.uncommittedChanges)),
        NamedCase("commits to push", (WorktreeCase(status: status(ahead: 2)), .commitsToPush)),
        NamedCase("commits to pull", (WorktreeCase(status: status(ahead: 0, behind: 3)), .commitsToPull)),
        NamedCase("a stopped operation", (WorktreeCase(status: status(stopped: .rebase)), .stoppedOperation)),
        NamedCase(
            "checks failing",
            (WorktreeCase(status: status(), pullRequest: .open(openPullRequest(checks: .failing))), .pullRequestAttention)
        ),
        NamedCase(
            "changes requested",
            (WorktreeCase(status: status(), pullRequest: .open(openPullRequest(review: .changesRequested))), .pullRequestAttention)
        ),
        NamedCase("merged and ready to clean up", (WorktreeCase(status: status(), pullRequest: .merged(mergedPullRequest)), .mergedReadyToCleanUp)),
        NamedCase(
            "a pushed branch with no pull request",
            (WorktreeCase(status: status(ahead: 0), pullRequest: .noPullRequest), .branchWithoutPullRequest)
        ),
    ])
    func reasons(_ testCase: NamedCase<(WorktreeCase, NeedsYouReason)>) throws {
        let (worktree, reason) = testCase.value
        #expect(try piece(worktree, settings: everyReason).reasons == [reason])

        var others = everyReason
        others.needsYouReasons.remove(reason)
        let without = try piece(worktree, settings: others)
        #expect(without.reasons.isEmpty)
        #expect(without.headline == nil)
        #expect(without.phase == .quiet)
    }

    @Test("a worktree without a status has no reasons, whatever its pull request says")
    func noStatus() throws {
        let work = try piece(WorktreeCase(status: nil, pullRequest: .open(openPullRequest(checks: .failing))), settings: everyReason)
        #expect(!work.hasStatus)
        #expect(work.reasons.isEmpty)
    }

    @Test("merged and ready to clean up needs the branch at its merged pull request's head, and nothing changed", arguments: [
        NamedCase("ready", (WorktreeCase(status: status(), pullRequest: .merged(mergedPullRequest)), true)),
        NamedCase("the tip moved on", (WorktreeCase(status: status(), pullRequest: .merged(mergedPullRequest), tip: "2222"), false)),
        NamedCase("the tip isn't known", (WorktreeCase(status: status(), pullRequest: .merged(mergedPullRequest), tip: nil), false)),
        NamedCase("changed files", (WorktreeCase(status: status(changed: 1), pullRequest: .merged(mergedPullRequest)), false)),
        NamedCase("no pull request", (WorktreeCase(status: status(), pullRequest: .noPullRequest), false)),
        NamedCase("its pull request isn't known", (WorktreeCase(status: status(), pullRequest: nil), false)),
        NamedCase(
            "detached at the merged commit",
            (WorktreeCase(status: status(head: .detached(sha: mergedTip)), pullRequest: .merged(mergedPullRequest)), false)
        ),
    ])
    func mergedAndReady(_ testCase: NamedCase<(WorktreeCase, Bool)>) throws {
        let work = try piece(testCase.value.0)
        #expect(work.reasons.contains(.mergedReadyToCleanUp) == testCase.value.1)
        if testCase.value.1 {
            #expect(work.headline == .merged(mergedPullRequest))
            #expect(work.nextStep == .cleanUp)
            #expect(work.phase == .needsYou)
        }
    }

    // MARK: Phases

    @Test("every piece of work is in one phase, by its reasons, how recently it changed, and its pull request's checks", arguments: [
        NamedCase("a stopped operation, changing now", (WorktreeCase(status: status(stopped: .merge), changedAgo: 60), WorkPhase.needsYou)),
        NamedCase(
            "checks failing, changing now",
            (WorktreeCase(status: status(changed: 1), pullRequest: .open(openPullRequest(checks: .failing)), changedAgo: 60), .needsYou)
        ),
        NamedCase(
            "merged, changed a moment ago",
            (WorktreeCase(status: status(), pullRequest: .merged(mergedPullRequest), changedAgo: 1), .needsYou)
        ),
        NamedCase("changed files, changed 5 minutes ago", (WorktreeCase(status: status(changed: 3), changedAgo: 5 * 60), .inProgress(.changingNow(changedFiles: 3)))),
        NamedCase("changed files, changed just under 10 minutes ago", (WorktreeCase(status: status(changed: 3), changedAgo: 10 * 60 - 1), .inProgress(.changingNow(changedFiles: 3)))),
        NamedCase("changed files, changed 10 minutes ago", (WorktreeCase(status: status(changed: 3), changedAgo: 10 * 60), .needsYou)),
        NamedCase("changed files sitting for days", (WorktreeCase(status: status(changed: 3), changedAgo: 3 * 24 * 60 * 60), .needsYou)),
        NamedCase("changed files, no time known", (WorktreeCase(status: status(changed: 3)), .needsYou)),
        NamedCase("commits to push, committed a minute ago", (WorktreeCase(status: status(ahead: 2), changedAgo: 60), .inProgress(.changingNow(changedFiles: 0)))),
        NamedCase(
            "nothing to do, its checks running",
            (WorktreeCase(status: status(ahead: 0), pullRequest: .open(openPullRequest(checks: .pending)), changedAgo: 60 * 60), .inProgress(.waitingOnChecks(pullRequest: 7)))
        ),
        NamedCase(
            "changed files and checks running, sitting",
            (WorktreeCase(status: status(changed: 1), pullRequest: .open(openPullRequest(checks: .pending)), changedAgo: 60 * 60), .needsYou)
        ),
        NamedCase("nothing to do, changing now", (WorktreeCase(status: status(), changedAgo: 60), .quiet)),
        NamedCase("only commits to pull, which don't count by default", (WorktreeCase(status: status(ahead: 0, behind: 2)), .quiet)),
        NamedCase("no status", (WorktreeCase(status: nil, changedAgo: 60), .quiet)),
    ])
    func phases(_ testCase: NamedCase<(WorktreeCase, WorkPhase)>) throws {
        #expect(try piece(testCase.value.0).phase == testCase.value.1)
    }

    // MARK: Headline

    @Test("the headline is the first reason that counts: stopped, checks failing, changes requested, files, push, merged, pull, no pull request")
    func headlinePriority() throws {
        let stopped = status(changed: 4, ahead: 2, behind: 1, stopped: .cherryPick, conflicted: 2)
        let failing = BranchPullRequestStatus.open(openPullRequest(checks: .failing, review: .changesRequested))
        var settings = everyReason
        func headline(_ status: RepositoryIndicator, _ pullRequest: BranchPullRequestStatus?) throws -> WorkHeadline? {
            try piece(WorktreeCase(status: status, pullRequest: pullRequest), settings: settings).headline
        }

        #expect(try headline(stopped, failing) == .operationStopped(.cherryPick, conflictedFiles: 2))
        settings.needsYouReasons.remove(.stoppedOperation)
        #expect(try headline(stopped, failing) == .checksFailing(openPullRequest(checks: .failing, review: .changesRequested)))
        #expect(try headline(stopped, .open(openPullRequest(review: .changesRequested))) == .changesRequested(openPullRequest(review: .changesRequested)))
        settings.needsYouReasons.remove(.pullRequestAttention)
        #expect(try headline(stopped, failing) == .filesChanged(4))
        settings.needsYouReasons.remove(.uncommittedChanges)
        #expect(try headline(stopped, failing) == .commitsToPush(2))
        settings.needsYouReasons.remove(.commitsToPush)
        #expect(try headline(status(ahead: 0, behind: 1), .merged(mergedPullRequest)) == .merged(mergedPullRequest))
        #expect(try headline(stopped, failing) == .commitsToPull(1))
        settings.needsYouReasons.remove(.commitsToPull)
        #expect(try headline(status(ahead: 0), .noPullRequest) == .pushedWithoutPullRequest)
        #expect(try headline(status(ahead: 0), .noPullRequest).map(\.nextStep) == .createPullRequest)
        settings.needsYouReasons.remove(.branchWithoutPullRequest)
        #expect(try headline(stopped, failing) == nil)
    }

    // MARK: Which worktrees, and what's unseen

    @Test("each repository's worktrees are pieces of work in order; a linked worktree two repositories list is the first one's")
    func worktrees() {
        let harbor = ModelFixtures.record(path: "/repositories/harbor")
        let pier = ModelFixtures.record(path: "/repositories/pier")
        let empty = ModelFixtures.record(path: "/repositories/empty")
        let work = makePiecesOfWork(WorkInputs(
            repositories: [harbor, pier, empty],
            worktrees: [
                harbor.id: [
                    WorktreeFacts(path: harbor.path, isCurrent: true, indicator: status()),
                    WorktreeFacts(path: "/worktrees/charts", isCurrent: false),
                ],
                pier.id: [
                    WorktreeFacts(path: "/worktrees/charts", isCurrent: false),
                    WorktreeFacts(path: pier.path, isCurrent: true),
                    // Another repository in the list.
                    WorktreeFacts(path: "/repositories/harbor", isCurrent: false),
                ],
            ],
            now: now
        ))
        #expect(work.map(\.id) == [
            WorktreeKey(repositoryID: harbor.id, path: harbor.path),
            WorktreeKey(repositoryID: harbor.id, path: "/worktrees/charts"),
            WorktreeKey(repositoryID: pier.id, path: pier.path),
            WorktreeKey(repositoryID: empty.id, path: empty.path),
        ])
        #expect(work.map(\.isCurrent) == [true, false, true, true])
        #expect(work.map(\.hasStatus) == [true, false, false, false])
    }

    @Test("activity of a kind that counts since a worktree was last open makes it unseen, never while it's open, and is its latest activity")
    func unseen() {
        let record = ModelFixtures.record(path: "/repositories/harbor")
        let key = WorktreeKey(repositoryID: record.id, path: record.path)
        let linked = WorktreeKey(repositoryID: record.id, path: "/worktrees/charts")
        let earlier = now.addingTimeInterval(-600)
        func work(open: WorktreeKey?, kinds: Set<WorktreeActivityKind> = [.files, .head, .server]) -> [PieceOfWork] {
            makePiecesOfWork(WorkInputs(
                repositories: [record],
                worktrees: [record.id: [
                    WorktreeFacts(path: record.path, isCurrent: true),
                    WorktreeFacts(path: linked.path, isCurrent: false),
                ]],
                activity: [
                    key: WorktreeActivity(files: now, lastOpen: earlier),
                    linked: WorktreeActivity(head: earlier, pullRequest: now, lastOpen: earlier.addingTimeInterval(-1)),
                ],
                openWorktree: open,
                settings: WorkSettings(activityKinds: kinds),
                now: now
            ))
        }

        #expect(work(open: nil).map(\.isUnseen) == [true, true])
        #expect(work(open: key).map(\.isUnseen) == [false, true])
        #expect(work(open: key).map(\.isOpen) == [true, false])
        #expect(work(open: nil).map(\.latestActivity) == [now, earlier])
        #expect(work(open: nil, kinds: [.files]).map(\.isUnseen) == [true, false])
        #expect(work(open: nil, kinds: [.files, .pullRequest]).map(\.latestActivity) == [now, now])
    }
}

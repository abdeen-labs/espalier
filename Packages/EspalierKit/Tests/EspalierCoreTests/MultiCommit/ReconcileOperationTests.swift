// The pure half of the conflict reducer (ConflictReconciler.swift), for
// the cases git can't easily produce; ConflictReconcilerTests and the
// operations' tests drive it with git.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing

@Suite("Reconciling the operation with its conflicts")
struct ReconcileOperationTests {
    let main = ModelFixtures.branch("main", sha: "main-sha", upstream: "origin/main")
    let feature = ModelFixtures.branch("feature", sha: "feature-sha")

    let starting = MultiCommitOperationProgress(value: 0, currentCommitSummary: "", position: 1, totalCommitCount: 0)

    /// A merge of `feature` into `main` that Espalier started.
    func espalierMerge(squash: Bool = false) -> MultiCommitOperation {
        MultiCommitOperation(
            kind: .merge,
            detail: .merge(sourceBranch: feature, isSquash: squash),
            phase: .running(starting),
            originalBranchTip: "main-sha",
            targetBranch: main,
            origin: .espalier
        )
    }

    func mergeConflictStatus(branch: String = "main", tip: String = "main-sha", mergeHead: Bool = true, squashMessage: Bool = false) -> StatusResult {
        makeConflictStatus(
            currentBranch: branch,
            currentUpstreamBranch: "origin/\(branch)",
            currentTip: tip,
            mergeHeadFound: mergeHead,
            squashMsgFound: squashMessage,
            doConflictedFilesExist: true
        )
    }

    func reconcile(_ operation: MultiCommitOperation?, _ status: StatusResult) -> MultiCommitOperation? {
        reconcileOperation(operation, conflictState: updateConflictState(nil, status), status: status)
    }

    @Test("conflicts on another branch are another operation, rebuilt")
    func anotherBranch() {
        let operation = reconcile(espalierMerge(), mergeConflictStatus(branch: "other", tip: "other-sha"))
        #expect(operation == MultiCommitOperation(
            kind: .merge,
            detail: .merge(sourceBranch: nil, isSquash: false),
            phase: .conflicted,
            originalBranchTip: "other-sha",
            targetBranch: Branch(name: "other", upstream: "origin/other", tip: BranchTip(sha: "other-sha"), type: .local, ref: "refs/heads/other"),
            origin: .rebuilt
        ))
    }

    @Test("a rebuilt merge is a squash merge only without MERGE_HEAD")
    func rebuiltSquash() {
        let squash = reconcile(nil, mergeConflictStatus(mergeHead: false, squashMessage: true))
        #expect(squash?.isSquashMerge == true)

        // A SQUASH_MSG left behind by an earlier squash merge doesn't make a
        // regular merge a squash merge.
        let stale = reconcile(nil, mergeConflictStatus(mergeHead: true, squashMessage: true))
        #expect(stale?.isSquashMerge == false)

        // Nor does it once the rebuilt operation exists.
        let later = reconcile(squash, mergeConflictStatus(mergeHead: true, squashMessage: true))
        #expect(later?.isSquashMerge == false)
    }

    @Test("an Espalier squash merge stays one while git agrees")
    func espalierSquash() {
        #expect(reconcile(espalierMerge(squash: true), mergeConflictStatus(mergeHead: false, squashMessage: true))?.isSquashMerge == true)
        #expect(reconcile(espalierMerge(squash: false), mergeConflictStatus(mergeHead: false, squashMessage: true))?.isSquashMerge == false)
    }

    @Test("a rebase's details follow the conflicts' current tip from round to round")
    func rebaseRounds() {
        let base = ModelFixtures.branch("main", sha: "base-sha")
        let commits = [CommitOneLine(sha: "c1", summary: "One"), CommitOneLine(sha: "c2", summary: "Two")]
        let operation = MultiCommitOperation(
            kind: .rebase,
            detail: .rebase(sourceBranch: base, commits: commits, currentTip: "base-sha"),
            phase: .continuing(starting),
            userHasResolvedConflicts: true,
            originalBranchTip: "original-sha",
            targetBranch: ModelFixtures.branch("topic", sha: "original-sha"),
            origin: .espalier
        )
        let status = makeConflictStatus(
            currentTip: "round-two-sha",
            rebaseInternalState: RebaseInternalState(targetBranch: "topic", baseBranchTip: "base-sha", originalBranchTip: "original-sha"),
            doConflictedFilesExist: true
        )
        var expected = operation
        expected.phase = .conflicted
        expected.detail = .rebase(sourceBranch: base, commits: commits, currentTip: "round-two-sha")
        #expect(reconcile(operation, status) == expected)
    }

    @Test("a cherry-pick onto a remote branch continues on its local branch")
    func cherryPickRemoteTarget() {
        let operation = MultiCommitOperation(
            kind: .cherryPick,
            detail: .cherryPick(sourceBranch: main, branchCreated: false, commits: [CommitOneLine(sha: "c1", summary: "One")]),
            phase: .running(starting),
            originalBranchTip: "x-sha",
            targetBranch: ModelFixtures.branch("origin/x", sha: "x-sha", type: .remote),
            origin: .espalier
        )
        let status = makeConflictStatus(currentBranch: "x", currentTip: "x-sha", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
        #expect(reconcile(operation, status)?.origin == .espalier)
    }

    @Test("a rebase git was interrupted in is rebuilt without conflicts, or keeps the operation it belongs to")
    func interruptedRebase() throws {
        let interrupted = RebaseInternalState(targetBranch: "topic", baseBranchTip: "base", originalBranchTip: "original")
        let status = makeConflictStatus(currentTip: "detached-sha")

        let rebuilt = reconcileOperation(nil, conflictState: nil, status: status, interruptedRebase: interrupted)
        #expect(rebuilt == MultiCommitOperation(
            kind: .rebase,
            detail: .rebase(sourceBranch: nil, commits: [], currentTip: "base"),
            phase: .interrupted,
            originalBranchTip: "original",
            targetBranch: Branch(name: "topic", upstream: nil, tip: BranchTip(sha: "original"), type: .local, ref: "refs/heads/topic"),
            origin: .rebuilt
        ))
        #expect(rebuilt?.interruptedMessage == "Rebasing topic was interrupted. Continue or abort the rebase.")
        // Nothing to load for it.
        #expect(enrichmentNeeded(for: rebuilt, conflictState: nil) == nil)

        // Espalier's rebase of the branch keeps what it knows.
        let topic = ModelFixtures.branch("topic", sha: "original")
        let espalierRebase = MultiCommitOperation(
            kind: .rebase,
            detail: .rebase(sourceBranch: main, commits: [CommitOneLine(sha: "c1", summary: "One")], currentTip: "base"),
            phase: .running(starting),
            originalBranchTip: "original",
            targetBranch: topic,
            origin: .espalier
        )
        var expected = espalierRebase
        expected.phase = .interrupted
        #expect(reconcileOperation(espalierRebase, conflictState: nil, status: status, interruptedRebase: interrupted) == expected)

        // Without one, no conflicts end any operation.
        #expect(reconcileOperation(espalierRebase, conflictState: nil, status: status) == nil)
        // Conflicts win: a rebase that stopped on them has REBASE_HEAD.
        let conflicted = makeConflictStatus(currentTip: "detached-sha", rebaseInternalState: interrupted, doConflictedFilesExist: true)
        #expect(reconcile(espalierRebase, conflicted)?.phase == .conflicted)
    }

    @Test("applies what was loaded only where it's missing")
    func applyingEnrichment() throws {
        let rebuilt = try #require(reconcile(nil, mergeConflictStatus()))
        let source = ModelFixtures.branch("feature", sha: "feature-sha")
        #expect(applyEnrichment(.mergeSource(source), to: rebuilt).detail == .merge(sourceBranch: source, isSquash: false))
        #expect(applyEnrichment(.mergeSource(nil), to: rebuilt) == rebuilt)

        let known = espalierMerge()
        #expect(applyEnrichment(.mergeSource(ModelFixtures.branch("other")), to: known) == known)

        let commits = [CommitOneLine(sha: "c1", summary: "One")]
        let rebaseStatus = makeConflictStatus(
            currentTip: "head",
            rebaseInternalState: RebaseInternalState(targetBranch: "topic", baseBranchTip: "base", originalBranchTip: "original"),
            doConflictedFilesExist: true
        )
        let rebase = try #require(reconcile(nil, rebaseStatus))
        let loaded = applyEnrichment(.commits(commits), to: rebase)
        #expect(loaded.detail == .rebase(sourceBranch: nil, commits: commits, currentTip: "base"))
        #expect(applyEnrichment(.commits([CommitOneLine(sha: "c9", summary: "Nine")]), to: loaded) == loaded)
    }

    // MARK: Resolutions

    static let markers = AppFileStatus.conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3))
    static let noMarkers = AppFileStatus.conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 0))
    static let binary = AppFileStatus.conflicted(.manualConflict(entry: UnmergedEntry(action: .bothModified)))

    @Test("a conflicted file needs its markers removed or a side chosen")
    func unresolved() {
        let files = [
            ModelFixtures.file("markers.txt", status: Self.markers),
            ModelFixtures.file("edited.txt", status: Self.noMarkers),
            ModelFixtures.file("image.png", status: Self.binary),
            ModelFixtures.file("clean.txt", status: .modified()),
        ]
        #expect(unresolvedConflictedFiles(files, [:]).map(\.path) == ["markers.txt", "image.png"])
        #expect(unresolvedConflictedFiles(files, ["image.png": .ours]).map(\.path) == ["markers.txt"])
        #expect(unresolvedConflictedFiles(files, ["image.png": .ours, "markers.txt": .theirs]).isEmpty)
    }

    @Test("a file whose markers were removed by hand keeps the edits over a chosen side")
    func effectiveResolutions() {
        let files = [
            ModelFixtures.file("edited.txt", status: Self.noMarkers),
            ModelFixtures.file("markers.txt", status: Self.markers),
            ModelFixtures.file("image.png", status: Self.binary),
        ]
        let resolutions: [String: ManualConflictResolution] = ["edited.txt": .theirs, "markers.txt": .ours, "image.png": .theirs]
        #expect(effectiveManualResolutions(resolutions, files: files) == ["markers.txt": .ours, "image.png": .theirs])
    }
}

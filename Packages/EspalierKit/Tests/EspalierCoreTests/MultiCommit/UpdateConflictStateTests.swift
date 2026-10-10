// Ported from desktop/app/test/unit/stores/updates/update-conflict-state-test.ts
//
// These cases assert the conflict state; a case named after usage counters
// keeps that name only as a comment. Manual resolutions carry over only
// within the same operation
// (`ConflictState.isSameOperation(as:)`): "preserves manual resolutions
// between updates in the same merge" uses one merge, and the rebase whose
// branch changed drops the resolutions. Further cases follow the ported
// ones.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport

/// A status with test defaults that the arguments override.
func makeConflictStatus(
    currentBranch: String? = nil,
    currentUpstreamBranch: String? = nil,
    currentTip: String? = nil,
    mergeHeadFound: Bool = false,
    squashMsgFound: Bool = false,
    rebaseInternalState: RebaseInternalState? = nil,
    isCherryPickingHeadFound: Bool = false,
    isRevertHeadFound: Bool = false,
    files: [WorkingDirectoryFileChange] = [],
    doConflictedFilesExist: Bool = false
) -> StatusResult {
    StatusResult(
        currentBranch: currentBranch,
        currentUpstreamBranch: currentUpstreamBranch,
        currentTip: currentTip,
        exists: true,
        mergeHeadFound: mergeHeadFound,
        squashMsgFound: squashMsgFound,
        rebaseInternalState: rebaseInternalState,
        isCherryPickingHeadFound: isCherryPickingHeadFound,
        isRevertHeadFound: isRevertHeadFound,
        workingDirectory: .fromFiles(files),
        doConflictedFilesExist: doConflictedFilesExist
    )
}

private let manualResolutions: [String: ManualConflictResolution] = ["foo": .theirs]

@Suite("updateConflictState")
struct UpdateConflictStateTests {
    @Suite("merge conflicts")
    struct MergeConflicts {
        @Test("returns null when no MERGE_HEAD file found")
        func mergeHeadGone() {
            let previous = ConflictState.merge(currentBranch: "old-branch", currentTip: "old-sha", manualResolutions: manualResolutions)
            #expect(updateConflictState(previous, makeConflictStatus(mergeHeadFound: false)) == nil)
        }

        @Test("preserves manual resolutions between updates in the same merge")
        func preservesResolutions() {
            // The previous state is the same merge: resolutions carry over for
            // the same merge only.
            let previous = ConflictState.merge(currentBranch: "master", currentTip: "first-sha", manualResolutions: manualResolutions)
            let status = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", mergeHeadFound: true, doConflictedFilesExist: true)

            #expect(updateConflictState(previous, status) == .merge(
                currentBranch: "master",
                currentTip: "first-sha",
                manualResolutions: manualResolutions
            ))
        }

        @Test("returns null when MERGE_HEAD set but not branch or tip defined")
        func noBranchOrTip() {
            let previous = ConflictState.merge(currentBranch: "old-branch", currentTip: "old-sha", manualResolutions: manualResolutions)
            let status = makeConflictStatus(currentBranch: nil, currentTip: nil, mergeHeadFound: true)
            #expect(updateConflictState(previous, status) == nil)
        }

        @Test("returns a value when status has MERGE_HEAD set and in conflicted state")
        func conflicted() {
            let status = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", mergeHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, status) == .merge(currentBranch: "master", currentTip: "first-sha", manualResolutions: [:]))
        }

        @Test("drops the manual resolutions of another merge")
        func dropsAnotherMergesResolutions() {
            // The data of "preserves manual resolutions between updates in the
            // same merge": "foo: theirs" isn't carried into a merge the user
            // never chose it for.
            let previous = ConflictState.merge(currentBranch: "old-branch", currentTip: "old-sha", manualResolutions: manualResolutions)
            let status = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", mergeHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(previous, status)?.manualResolutions == [:])

            // The same branch at another tip is another merge too.
            let sameBranch = ConflictState.merge(currentBranch: "master", currentTip: "old-sha", manualResolutions: manualResolutions)
            #expect(updateConflictState(sameBranch, status)?.manualResolutions == [:])
        }

        @Test("drops manual resolutions when another kind of operation conflicts")
        func dropsResolutionsAcrossKinds() {
            let previous = ConflictState.merge(currentBranch: "master", currentTip: "first-sha", manualResolutions: manualResolutions)
            let status = makeConflictStatus(
                currentTip: "first-sha",
                rebaseInternalState: RebaseInternalState(targetBranch: "master", baseBranchTip: "base", originalBranchTip: "first-sha"),
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(previous, status)?.manualResolutions == [:])
        }

        @Test("a squash merge has conflicts only while conflicted files exist")
        func squashMerge() {
            let conflicted = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", squashMsgFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, conflicted) == .merge(currentBranch: "master", currentTip: "first-sha", manualResolutions: [:]))

            // A SQUASH_MSG alone is no merge in progress.
            let resolved = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", squashMsgFound: true, doConflictedFilesExist: false)
            #expect(updateConflictState(nil, resolved) == nil)

            // A merge with MERGE_HEAD whose conflicts are all resolved still
            // waits to be committed.
            let allResolved = makeConflictStatus(currentBranch: "master", currentTip: "first-sha", mergeHeadFound: true, doConflictedFilesExist: false)
            #expect(updateConflictState(nil, allResolved) == .merge(currentBranch: "master", currentTip: "first-sha", manualResolutions: [:]))
        }
    }

    @Suite("rebase conflicts")
    struct RebaseConflicts {
        @Test("returns null when no REBASE_HEAD file found")
        func rebaseStateGone() {
            let previous = ConflictState.rebase(
                currentTip: "old-sha",
                targetBranch: "my-feature-branch",
                baseBranch: nil,
                originalBranchTip: "some-other-sha",
                baseBranchTip: "another-sha",
                manualResolutions: manualResolutions
            )
            #expect(updateConflictState(previous, makeConflictStatus(rebaseInternalState: nil)) == nil)
        }

        @Test("returns a value when status has REBASE_HEAD set and conflict present")
        func conflicted() {
            let status = makeConflictStatus(
                currentBranch: "master",
                currentTip: "first-sha",
                rebaseInternalState: RebaseInternalState(
                    targetBranch: "my-feature-branch",
                    baseBranchTip: "another-sha",
                    originalBranchTip: "some-other-sha"
                ),
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(nil, status) == .rebase(
                currentTip: "first-sha",
                targetBranch: "my-feature-branch",
                baseBranch: nil,
                originalBranchTip: "some-other-sha",
                baseBranchTip: "another-sha",
                manualResolutions: [:]
            ))
        }

        @Test("preserves manual resolutions when a rebase is detected")
        func preservesResolutions() {
            let previous = ConflictState.rebase(
                currentTip: "old-sha",
                targetBranch: "my-feature-branch",
                baseBranch: nil,
                originalBranchTip: "some-other-sha",
                baseBranchTip: "another-sha",
                manualResolutions: manualResolutions
            )
            let status = makeConflictStatus(
                currentBranch: "master",
                currentTip: "first-sha",
                rebaseInternalState: RebaseInternalState(
                    targetBranch: "my-feature-branch",
                    baseBranchTip: "another-sha",
                    originalBranchTip: "some-other-sha"
                ),
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(previous, status) == .rebase(
                currentTip: "first-sha",
                targetBranch: "my-feature-branch",
                baseBranch: nil,
                originalBranchTip: "some-other-sha",
                baseBranchTip: "another-sha",
                manualResolutions: manualResolutions
            ))
        }

        // "increments abort counter when conflict remains but branch has
        // changed": no usage counters, so this checks the conflict state.
        @Test("another rebase's conflicts replace the previous rebase's")
        func branchChanged() {
            let previous = ConflictState.rebase(
                currentTip: "current-sha",
                targetBranch: "my-feature-branch",
                baseBranch: nil,
                originalBranchTip: "old-sha",
                baseBranchTip: "another-sha",
                manualResolutions: manualResolutions
            )
            let status = makeConflictStatus(
                currentTip: "current-sha",
                rebaseInternalState: RebaseInternalState(
                    targetBranch: "a-different-feature-branch",
                    baseBranchTip: "an-even-older-sha",
                    originalBranchTip: "some-old-sha"
                ),
                doConflictedFilesExist: true
            )
            // Another rebase: the resolutions are dropped.
            #expect(updateConflictState(previous, status) == .rebase(
                currentTip: "current-sha",
                targetBranch: "a-different-feature-branch",
                baseBranch: nil,
                originalBranchTip: "some-old-sha",
                baseBranchTip: "an-even-older-sha",
                manualResolutions: [:]
            ))
        }
    }

    @Suite("cherry-pick conflicts")
    struct CherryPickConflicts {
        @Test("returns a value when CHERRY_PICK_HEAD is found on a branch")
        func conflicted() {
            let status = makeConflictStatus(currentBranch: "main", currentTip: "sha", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, status) == .cherryPick(targetBranchName: "main", manualResolutions: [:]))
        }

        @Test("returns null without a current branch")
        func detached() {
            let status = makeConflictStatus(currentTip: "sha", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, status) == nil)
        }

        @Test("a rebase wins over a cherry-pick, and a cherry-pick over a merge")
        func priority() {
            let rebase = RebaseInternalState(targetBranch: "topic", baseBranchTip: "base", originalBranchTip: "original")
            let all = makeConflictStatus(
                currentBranch: "main",
                currentTip: "sha",
                mergeHeadFound: true,
                rebaseInternalState: rebase,
                isCherryPickingHeadFound: true,
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(nil, all)?.family == .rebase)

            let cherryPickAndMerge = makeConflictStatus(
                currentBranch: "main",
                currentTip: "sha",
                mergeHeadFound: true,
                isCherryPickingHeadFound: true,
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(nil, cherryPickAndMerge)?.family == .cherryPick)
        }

        @Test("keeps manual resolutions for the same target branch")
        func preservesResolutions() {
            let previous = ConflictState.cherryPick(targetBranchName: "main", manualResolutions: ["foo": .ours])
            let status = makeConflictStatus(currentBranch: "main", currentTip: "next", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(previous, status)?.manualResolutions == ["foo": .ours])

            let elsewhere = makeConflictStatus(currentBranch: "other", currentTip: "next", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(previous, elsewhere)?.manualResolutions == [:])
        }
    }

    @Suite("revert conflicts")
    struct RevertConflicts {
        @Test("returns a value when REVERT_HEAD is found on a branch")
        func conflicted() {
            let status = makeConflictStatus(currentBranch: "main", currentTip: "sha", isRevertHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, status) == .revert(targetBranchName: "main", manualResolutions: [:]))
            // Resolved and staged, not committed yet: still waiting.
            let resolved = makeConflictStatus(currentBranch: "main", currentTip: "sha", isRevertHeadFound: true)
            #expect(updateConflictState(nil, resolved) == .revert(targetBranchName: "main", manualResolutions: [:]))
        }

        @Test("returns null without a current branch")
        func detached() {
            let status = makeConflictStatus(currentTip: "sha", isRevertHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(nil, status) == nil)
        }

        @Test("a cherry-pick wins over a revert, and a revert over a merge")
        func priority() {
            let cherryPickAndRevert = makeConflictStatus(
                currentBranch: "main",
                currentTip: "sha",
                isCherryPickingHeadFound: true,
                isRevertHeadFound: true,
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(nil, cherryPickAndRevert)?.family == .cherryPick)

            let revertAndMerge = makeConflictStatus(
                currentBranch: "main",
                currentTip: "sha",
                mergeHeadFound: true,
                isRevertHeadFound: true,
                doConflictedFilesExist: true
            )
            #expect(updateConflictState(nil, revertAndMerge)?.family == .revert)
        }

        @Test("keeps manual resolutions for the same target branch")
        func preservesResolutions() {
            let previous = ConflictState.revert(targetBranchName: "main", manualResolutions: ["foo": .theirs])
            let status = makeConflictStatus(currentBranch: "main", currentTip: "sha", isRevertHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(previous, status)?.manualResolutions == ["foo": .theirs])

            let cherryPick = makeConflictStatus(currentBranch: "main", currentTip: "sha", isCherryPickingHeadFound: true, doConflictedFilesExist: true)
            #expect(updateConflictState(previous, cherryPick)?.manualResolutions == [:])
        }
    }
}

// How multi-commit operations report progress (coalesced), and the
// clean-up of a rebase whose task was cancelled (`abortRebase` after
// cancelling a rebase).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Multi-commit progress and clean-up") @MainActor
struct MultiCommitProgressTests {
    private final class Received {
        var progress: [AnyProgress] = []
    }

    private func progress(_ position: Int, of total: Int = 4, _ summary: String) -> MultiCommitOperationProgress {
        MultiCommitOperationProgress(
            value: Double(position) / Double(total),
            currentCommitSummary: summary,
            position: position,
            totalCommitCount: total
        )
    }

    @Test("reports to the activity and to the running operation's phase; the last report wins")
    func reports() {
        let model = MultiCommitOperationsModel()
        model.current = MultiCommitOperation(
            kind: .rebase,
            detail: .rebase(sourceBranch: nil, commits: [], currentTip: "base"),
            phase: .running(initialProgress([])),
            origin: .espalier
        )
        let received = Received()
        let relay = ProgressRelay<AnyProgress> { received.progress.append($0) }
        let context = OperationContext(
            repository: Repository(path: "/nonexistent"),
            kind: .rebase,
            isBackgroundTask: false,
            hooks: .none,
            progress: ProgressSink(relay: relay),
            gitHubHTMLURL: nil,
            mainWorktreePath: nil
        )
        let reporter = model.progressReporter(context)

        reporter.callback(progress(1, "One"))
        reporter.callback(progress(2, "Two"))
        reporter.finish()
        relay.flush()
        #expect(model.current?.phase == .running(progress(2, "Two")))
        #expect(received.progress == [.multiCommitOperation(progress(2, "Two"))])

        model.current?.phase = .continuing(initialProgress([]))
        reporter.callback(progress(3, "Three"))
        reporter.finish()
        #expect(model.current?.phase == .continuing(progress(3, "Three")))

        // Stopped on conflicts, or ended: reports don't bring it back.
        model.current?.phase = .conflicted
        reporter.callback(progress(4, "Four"))
        reporter.finish()
        #expect(model.current?.phase == .conflicted)
        model.current = nil
        reporter.callback(progress(4, "Four"))
        reporter.finish()
        #expect(model.current == nil)
    }

    @Test("a rebase whose task was cancelled is still aborted")
    func abortsAfterCancellation() async throws {
        let repository = try await createRebaseTestRepository("base-branch", "feature-branch")
        let original = try await getBranchOrError(repository, "feature-branch").tip.sha
        #expect(try await runGitAllowingFailure(["rebase", "base-branch", "feature-branch"], repository) != 0)
        #expect(isRebaseStateDirectoryPresent(repository))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await abortRebaseStartedHere(repository)
        }
        await task.value

        #expect(!isRebaseStateDirectoryPresent(repository))
        #expect(try await currentBranchName(repository) == "feature-branch")
        #expect(try await getTipOrError(repository).sha == original)
    }

    @Test("finds a rebase interrupted between commits, and nothing otherwise")
    func interruptedState() async throws {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "readme\n")], commitMessage: "First"))
        try await createBranch(repository, "base-branch", "HEAD")
        try await createBranch(repository, "feature-branch", "HEAD")
        try await switchTo(repository, "base-branch")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "base.txt", contents: "base\n")], commitMessage: "Base"))
        try await switchTo(repository, "feature-branch")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "one.txt", contents: "one\n")], commitMessage: "One"))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "two.txt", contents: "two\n")], commitMessage: "Two"))
        #expect(await getInterruptedRebaseState(repository) == nil)
        let original = try await getBranchOrError(repository, "feature-branch").tip.sha
        let base = try await getBranchOrError(repository, "base-branch").tip.sha
        try await interruptRebase(of: "feature-branch", onto: "base-branch", in: repository)

        #expect(await getInterruptedRebaseState(repository) == RebaseInternalState(
            targetBranch: "feature-branch",
            baseBranchTip: base,
            originalBranchTip: original
        ))
        // git am's directory isn't a rebase.
        try await runGit(["rebase", "--abort"], repository)
        let am = POSIXPath.join(repository.resolvedGitDir, "rebase-apply")
        try FileManager.default.createDirectory(atPath: am, withIntermediateDirectories: true)
        for name in ["orig-head", "head-name", "onto"] {
            try Data("x\n".utf8).write(to: URL(filePath: POSIXPath.join(am, name)))
        }
        #expect(await getInterruptedRebaseState(repository) == nil)
        try Data().write(to: URL(filePath: POSIXPath.join(am, "rebasing")))
        #expect(await getInterruptedRebaseState(repository)?.targetBranch == "x")
    }
}

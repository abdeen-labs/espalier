// The size limits of GitDiff.swift's diffs, lowered for a test's task so a
// small diff is over them.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

/// A limit the diffs these tests read are all over.
private let smallLimit = 4 * 1024

/// 1,000 different lines, each starting with `prefix`.
private func lines(_ prefix: String) -> String {
    (0..<1000).map { "\(prefix) line \($0)\n" }.joined()
}

private func write(_ repo: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repo.path, path)))
}

@Suite("git/diff/size limit")
struct DiffSizeLimitTests {
    /// A diff function, and the change it reads.
    enum EntryPoint: Sendable {
        /// `getWorkingDirectoryDiff` for a modified file: `git diff HEAD`.
        case modified
        /// `getWorkingDirectoryDiff` for an untracked file:
        /// `git diff --no-index`.
        case untracked
        /// `getWorkingDirectoryDiff` for a renamed file, against the index.
        case renamed
        /// `getCommitDiff` for the last commit.
        case commit
        /// `getCommitRangeDiff` for the last commit.
        case commitRange
        /// `getCommitRangeDiff` from the first commit, which retries against
        /// the null tree.
        case commitRangeFromFirstCommit
        /// `getBranchMergeBaseDiff` from a branch at the first commit.
        case branchMergeBase
        /// `getResolutionDiff` of the working tree file and other content.
        case resolution
    }

    /// A repository whose first commit has file.txt with one line, also on
    /// the branch `base`, and whose second commit fills it with
    /// `lines("one")`; then the working tree change `entryPoint` reads.
    static func makeRepository(for entryPoint: EntryPoint) async throws -> Repository {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "short\n")]))
        _ = try await Dugite.exec(["branch", "base"], repo.path)
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: lines("one"))]))

        switch entryPoint {
        case .modified:
            try write(repo, "file.txt", lines("two"))
        case .untracked:
            try write(repo, "new.txt", lines("two"))
        case .renamed:
            _ = try await Dugite.exec(["mv", "file.txt", "moved.txt"], repo.path)
            try write(repo, "moved.txt", lines("two"))
        case .commit, .commitRange, .commitRangeFromFirstCommit, .branchMergeBase, .resolution:
            break
        }
        return repo
    }

    /// The diff `entryPoint` gives in a repository from `makeRepository`.
    static func diff(_ entryPoint: EntryPoint, _ repo: Repository) async throws -> Diff {
        let committed = PlainFileChange("file.txt", .modified())
        switch entryPoint {
        case .modified:
            return try await getWorkingDirectoryDiff(repo, workingDirectoryFile("file.txt", .modified()))
        case .untracked:
            return try await getWorkingDirectoryDiff(repo, workingDirectoryFile("new.txt", .untracked()))
        case .renamed:
            let status = AppFileStatus.renamed(oldPath: "file.txt", renameIncludesModifications: true)
            return try await getWorkingDirectoryDiff(repo, workingDirectoryFile("moved.txt", status))
        case .commit:
            return try await getCommitDiff(repo, committed, "HEAD")
        case .commitRange:
            return try await getCommitRangeDiff(repo, committed, ["HEAD"])
        case .commitRangeFromFirstCommit:
            let shas = try await getCommits(repo, "HEAD", limit: 2).map(\.sha)
            return try await getCommitRangeDiff(repo, committed, Array(shas.reversed()))
        case .branchMergeBase:
            let tip = try await getTipOrError(repo)
            return try await getBranchMergeBaseDiff(repo, committed, "base", "master", latestCommit: tip.sha)
        case .resolution:
            return try await getResolutionDiff(repo, "file.txt", .content(lines("two"))).diff
        }
    }

    static func workingDirectoryFile(_ path: String, _ status: AppFileStatus) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(path: path, status: status, selection: .fromInitialSelection(.all))
    }

    // Git stops once its output is past the limit, and the diff is the
    // `.unrenderable` it would be with the whole output.
    @Test("gives an unrenderable diff for output over the limit", arguments: [
        NamedCase("a modified file", .modified),
        NamedCase("an untracked file", .untracked),
        NamedCase("a renamed file", .renamed),
        NamedCase("a commit", .commit),
        NamedCase("a range of commits", .commitRange),
        NamedCase("a range from the first commit", .commitRangeFromFirstCommit),
        NamedCase("a merge-base diff", .branchMergeBase),
        NamedCase("a resolution diff", .resolution),
    ] as [NamedCase<EntryPoint>])
    func overLimit(_ testCase: NamedCase<EntryPoint>) async throws {
        let repo = try await Self.makeRepository(for: testCase.value)
        #expect(try await Self.diff(testCase.value, repo).kind == .text)

        let limited = try await DiffLimits.$maxBufferSize.withValue(smallLimit) {
            try await Self.diff(testCase.value, repo)
        }
        #expect(limited == .unrenderable)
    }

    // Output one byte over the limit is read whole and refused; more stops
    // git.
    @Test("shows a diff exactly at the limit and none over it", arguments: [
        NamedCase("exactly at the limit", (overBy: 0, kind: DiffType.text)),
        NamedCase("a byte over", (overBy: 1, kind: DiffType.unrenderable)),
        NamedCase("two bytes over", (overBy: 2, kind: DiffType.unrenderable)),
    ] as [NamedCase<(overBy: Int, kind: DiffType)>])
    func atLimit(_ testCase: NamedCase<(overBy: Int, kind: DiffType)>) async throws {
        let repo = try await Self.makeRepository(for: .modified)
        // The output getWorkingDirectoryDiff reads.
        let output = try await Dugite.exec(
            ["diff", "--no-ext-diff", "--patch-with-raw", "-z", "--no-color", "HEAD", "--", "file.txt"],
            repo.path
        ).stdout

        let diff = try await DiffLimits.$maxBufferSize.withValue(output.count - testCase.value.overBy) {
            try await Self.diff(.modified, repo)
        }
        #expect(diff.kind == testCase.value.kind)
    }

    @Test("refuses files' diff text over its limit")
    func filesDiffText() async throws {
        let repo = try await Self.makeRepository(for: .modified)
        let file = Self.workingDirectoryFile("file.txt", .modified())
        #expect(try await getFilesDiffText(repo, [file]).contains("+two line 999"))

        _ = await DiffLimits.$maxFilesDiffTextSize.withValue(smallLimit) {
            await #expect(throws: GitLibError.self) {
                _ = try await getFilesDiffText(repo, [file])
            }
        }
    }
}

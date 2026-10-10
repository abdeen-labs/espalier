// Ported from desktop/app/test/unit/git/diff-stage-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

/// A text diff, or nil (recording an issue) for any other kind.
private func textDiff(_ diff: Diff, sourceLocation: SourceLocation = #_sourceLocation) -> TextDiff? {
    #expect(diff.kind == .text, sourceLocation: sourceLocation)
    guard case .text(let textDiff) = diff else {
        return nil
    }
    return textDiff
}

@Suite("git/diff/getResolutionDiff (stage mode)")
struct DiffStageTests {
    @Test("diffs a stage against the on-disk conflict-marker file", arguments: [
        // Diff: on-disk (conflict markers) → :2 (master's version)
        NamedCase("diffs ours (:2) against the on-disk conflict-marker file", (stage: ResolutionStage.ours, removed: "-feature change")),
        // Diff: on-disk (conflict markers) → :3 (feature's version)
        NamedCase("diffs theirs (:3) against the on-disk conflict-marker file", (stage: ResolutionStage.theirs, removed: "-master change")),
    ])
    func stage(_ testCase: NamedCase<(stage: ResolutionStage, removed: String)>) async throws {
        let (stage, removed) = testCase.value
        let repo = try setupEmptyRepository()

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "line 1\nline 2\nline 3\n")],
            commitMessage: "base"
        ))

        try await switchTo(repo, "feature")
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "line 1\nfeature change\nline 3\n")],
            commitMessage: "feature"
        ))

        _ = try await Dugite.exec(["checkout", "master"], repo.path)
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "line 1\nmaster change\nline 3\n")],
            commitMessage: "master"
        ))

        _ = try await Dugite.exec(["merge", "feature", "--no-commit"], repo.path)

        let result = try await getResolutionDiff(repo, "file.txt", .stage(stage))

        let diff = try #require(textDiff(result.diff))
        #expect(diff.hunks.count > 0)
        // The conflict markers from the on-disk file should appear as removed
        #expect(diff.text.contains(removed), "should remove the other side")
    }

    @Test("shows deletion diff when file deleted in requested stage")
    func deletedInStage() async throws {
        let repo = try setupEmptyRepository()

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "base content\n")],
            commitMessage: "base"
        ))

        try await switchTo(repo, "feature")
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: nil)],
            commitMessage: "feature deletes file"
        ))

        _ = try await Dugite.exec(["checkout", "master"], repo.path)
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "master modified\n")],
            commitMessage: "master modifies file"
        ))

        _ = try await Dugite.exec(["merge", "feature", "--no-commit"], repo.path)

        // file.txt was deleted in feature (:3 doesn't exist) → empty target.
        // Diff should show the on-disk content being removed entirely.
        let result = try await getResolutionDiff(repo, "file.txt", .stage(.theirs))

        let diff = try #require(textDiff(result.diff))
        #expect(diff.text.contains("-master modified"), "should show on-disk content as deleted")
        #expect(result.newContents == "")
    }

    // Master's spacing change merges cleanly above the conflict, where the
    // flag hides it (inside the conflict, the diff would be the same with or
    // without the flag).
    @Test("respects hideWhitespaceInDiff flag")
    func hideWhitespace() async throws {
        let repo = try setupEmptyRepository()

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "hello world\na\nb\nc\nd\nend\n")],
            commitMessage: "base"
        ))

        try await switchTo(repo, "feature")
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "hello world\na\nb\nc\nd\nfeature end\n")],
            commitMessage: "feature"
        ))

        _ = try await Dugite.exec(["checkout", "master"], repo.path)
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "hello  world\na\nb\nc\nd\nmaster end\n")],
            commitMessage: "master"
        ))

        _ = try await Dugite.exec(["merge", "feature", "--no-commit"], repo.path)

        // With whitespace hidden, spacing-only changes should be suppressed
        let result = try await getResolutionDiff(repo, "file.txt", .stage(.theirs), hideWhitespaceInDiff: true)

        let diff = try #require(textDiff(result.diff))
        // The conflict's changes should still appear
        #expect(diff.text.contains("-master end"), "should show non-whitespace changes")
        #expect(!diff.text.contains("hello  world"), "should hide the spacing change")

        // Without the flag, the spacing change shows.
        let shown = try await getResolutionDiff(repo, "file.txt", .stage(.theirs))
        let shownDiff = try #require(textDiff(shown.diff))
        #expect(shownDiff.text.contains("-hello  world\n+hello world"))
        #expect(shownDiff.text.contains("-master end"))
    }
}

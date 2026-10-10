// Ported from desktop/app/test/unit/git/revision-consumers-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// Runs git with dugite's `exec`, requires it to succeed, and returns its
/// trimmed output.
@discardableResult
private func runGit(_ repository: Repository, _ args: [String]) async throws -> String {
    let result = try await Dugite.exec(args, repository.path)
    try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    return JSCompat.trim(String(decoding: result.stdout, as: UTF8.self))
}

/// Three commits, `base`, `first`, and `tip`, with `refs/remotes/--remote/base`
/// at `base` and `refs/remotes/--remote/main` at `tip`.
private func setupHistory() async throws -> (repository: Repository, base: String, first: String, tip: String) {
    let repository = try setupEmptyRepository()
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "file.txt", contents: "base\n")],
        commitMessage: "base"
    ))
    let base = try await runGit(repository, ["rev-parse", "HEAD"])
    try await runGit(repository, ["update-ref", "refs/remotes/--remote/base", base])
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "file.txt", contents: "updated\n")],
        commitMessage: "matching first"
    ))
    let first = try await runGit(repository, ["rev-parse", "HEAD"])
    try await makeCommit(repository, Tree(
        entries: [TreeEntry(path: "other.txt", contents: "other\n")],
        commitMessage: "matching second"
    ))
    let tip = try await runGit(repository, ["rev-parse", "HEAD"])
    try await runGit(repository, ["update-ref", "refs/remotes/--remote/main", tip])
    return (repository, base, first, tip)
}

/// The fields of a changed file the tests compare.
private struct ChangedFile: Equatable {
    let path: String
    let kind: AppFileStatusKind
    let commitish: String
    let parentCommitish: String

    init(path: String, kind: AppFileStatusKind, commitish: String, parentCommitish: String) {
        self.path = path
        self.kind = kind
        self.commitish = commitish
        self.parentCommitish = parentCommitish
    }

    init(_ file: CommittedFileChange) {
        self.init(path: file.path, kind: file.status.kind, commitish: file.commitish, parentCommitish: file.parentCommitish)
    }
}

private func requireTextDiff(_ diff: Diff) throws -> TextDiff {
    #expect(diff.kind == .text)
    guard case .text(let textDiff) = diff else {
        throw TestSupportError("Expected a text diff, got \(diff.kind)")
    }
    return textDiff
}

@Suite("revision consumers with leading-dash refs")
struct RevisionConsumersTests {
    @Test("getBranchMergeBaseChangedFiles preserves file statuses, statistics, and revisions")
    func branchMergeBaseChangedFiles() async throws {
        let (repository, base, _, tip) = try await setupHistory()
        for (from, to) in [
            ("--remote/base", "--remote/main"),
            (base, "--remote/main"),
            ("--remote/base", tip),
        ] {
            let changes = try #require(try await getBranchMergeBaseChangedFiles(repository, from, to, tip))
            #expect(changes.linesAdded == 2)
            #expect(changes.linesDeleted == 1)
            #expect(changes.files.map(ChangedFile.init) == [
                ChangedFile(path: "file.txt", kind: .modified, commitish: tip, parentCommitish: base),
                ChangedFile(path: "other.txt", kind: .new, commitish: tip, parentCommitish: base),
            ])
        }
        try await runGit(repository, ["mv", "--", "file.txt", "-file.txt"])
        try await runGit(repository, ["commit", "-m", "rename file"])
        let renamed = try await runGit(repository, ["rev-parse", "HEAD"])
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/renamed", renamed])
        let changes = try #require(
            try await getBranchMergeBaseChangedFiles(repository, "--remote/main", "--remote/renamed", renamed)
        )
        #expect(changes.linesAdded == 0)
        #expect(changes.linesDeleted == 0)
        try #require(changes.files.count == 1)
        #expect(changes.files[0].path == "-file.txt")
        #expect(changes.files[0].status == .renamed(
            oldPath: "file.txt",
            renameIncludesModifications: false,
            submoduleStatus: nil
        ))
    }

    @Test("getBranchMergeBaseDiff reads leading-dash refs and limits output to the requested file")
    func branchMergeBaseDiff() async throws {
        let (repository, base, _, tip) = try await setupHistory()
        let file = PlainFileChange("file.txt", .modified())
        for (from, to) in [
            ("--remote/base", "--remote/main"),
            (base, "--remote/main"),
            ("--remote/base", tip),
        ] {
            let diff = try requireTextDiff(try await getBranchMergeBaseDiff(
                repository,
                file,
                from,
                to,
                hideWhitespaceInDiff: false,
                latestCommit: tip
            ))
            #expect(diff.text == "@@ -1 +1 @@\n-base\n+updated")
            #expect(!diff.text.contains("other.txt"))
        }
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "  updated \n")]))
        let spaced = try await runGit(repository, ["rev-parse", "HEAD"])
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/spaced", spaced])
        let hidden = try requireTextDiff(try await getBranchMergeBaseDiff(
            repository,
            file,
            "--remote/main",
            "--remote/spaced",
            hideWhitespaceInDiff: true,
            latestCommit: spaced
        ))
        #expect(hidden.hunks.isEmpty)
    }

    @Test("getBranchMergeBaseDiff preserves old and leading-dash new paths for renames")
    func branchMergeBaseDiffRename() async throws {
        let (repository, _, _, _) = try await setupHistory()
        try await runGit(repository, ["mv", "--", "file.txt", "-file.txt"])
        try await runGit(repository, ["commit", "-m", "rename file"])
        let renamed = try await runGit(repository, ["rev-parse", "HEAD"])
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/renamed", renamed])
        let diff = try requireTextDiff(try await getBranchMergeBaseDiff(
            repository,
            PlainFileChange("-file.txt", .renamed(oldPath: "file.txt", renameIncludesModifications: false)),
            "--remote/main",
            "--remote/renamed",
            hideWhitespaceInDiff: false,
            latestCommit: renamed
        ))
        #expect(diff.text == "")
        #expect(diff.hunks.isEmpty)
    }

    @Test("partial blob readers read leading-dash refs and preserve missing-path handling")
    func partialBlobReaders() async throws {
        let (repository, base, _, _) = try await setupHistory()
        let readers: [(name: String, read: (Repository, String, String, Int) async throws -> Data?)] = [
            ("getPartialBlobContents", getPartialBlobContents),
            ("getPartialBlobContentsCatchPathNotInRef", getPartialBlobContentsCatchPathNotInRef),
        ]
        for (name, read) in readers {
            #expect(try await read(repository, "--remote/base", "file.txt", 1024) == Data("base\n".utf8), "\(name)")
            #expect(try await read(repository, base, "other.txt", 1024) == nil, "\(name)")
            for revision in [
                "--remote/base",
                "--remote/main~2",
                "--remote/base^{tree}",
            ] {
                #expect(try await read(repository, revision, "file.txt", 1024) == Data("base\n".utf8), "\(name) \(revision)")
                #expect(try await read(repository, revision, "other.txt", 1024) == nil, "\(name) \(revision)")
            }
            for revision in ["--remote/missing", "missing-ref"] {
                await #expect(throws: GitError.self, "\(name) \(revision)") {
                    try await read(repository, revision, "other.txt", 1024)
                }
            }
        }

        let contents = Data(Array(repeating: [0, 255, 128, 10] as [UInt8], count: 1024 * 1024 / 4).joined())
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "large.bin", contents: contents)]))
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/large", "HEAD"])
        let partial = try await getPartialBlobContents(repository, "--remote/large", "large.bin", 8)
        let read = try #require(partial)
        #expect(!read.isEmpty)
        #expect(read == contents.prefix(read.count))
    }

    @Test("getBlobContents reads exact binary contents from leading-dash refs")
    func blobContents() async throws {
        let (repository, _, _, _) = try await setupHistory()
        let contents = Data([0, 255, 13, 10, 128])
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "binary file.bin", contents: contents)]))
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/blob", "HEAD"])
        #expect(try await getBlobContents(repository, "--remote/blob", "binary file.bin") == contents)
        #expect(try await getBlobContents(repository, "--remote/base", "file.txt") == Data("base\n".utf8))
        for revision in [
            "--remote/base",
            "--remote/main~2",
            "--remote/base^{tree}",
        ] {
            #expect(try await getBlobContents(repository, revision, "file.txt") == Data("base\n".utf8), "\(revision)")
            let error = await #expect(throws: GitError.self, "\(revision)") {
                try await getBlobContents(repository, revision, "other.txt")
            }
            #expect(error?.message.contains("path 'other.txt' exists on disk, but not in") == true, "\(revision)")
        }
        for revision in ["--remote/missing", "missing-ref"] {
            await #expect(throws: GitError.self, "\(revision)") {
                try await getBlobContents(repository, revision, "other.txt")
            }
        }
    }

    @Test("doMergeCommitsExistAfterCommit detects merges after leading-dash refs")
    func mergeCommitsAfterCommit() async throws {
        let (repository, base, _, tip) = try await setupHistory()
        #expect(try await doMergeCommitsExistAfterCommit(repository, "--remote/base") == false)
        try await runGit(repository, ["checkout", "-b", "side", base])
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "side.txt", contents: "side\n")]))
        try await runGit(repository, ["checkout", "--detach", tip])
        try await runGit(repository, ["merge", "--no-ff", "-m", "merge side", "side"])
        #expect(try await doMergeCommitsExistAfterCommit(repository, "--remote/base") == true)
        #expect(try await doMergeCommitsExistAfterCommit(repository, nil) == true)
        try await runGit(repository, ["update-ref", "refs/remotes/--remote/merged", "HEAD"])
        #expect(try await doMergeCommitsExistAfterCommit(repository, "--remote/merged") == false)
    }

    @Test("getCommitsInRange preserves order and summaries for leading-dash ranges")
    func commitsInRange() async throws {
        let (repository, _, first, tip) = try await setupHistory()
        #expect(try await getCommitsInRange(repository, "--remote/base..--remote/main") == [
            CommitOneLine(sha: first, summary: "matching first"),
            CommitOneLine(sha: tip, summary: "matching second"),
        ])
        #expect(try await getCommitsInRange(repository, "--remote/main..HEAD") == [])
        #expect(try await getCommitsInRange(repository, "--remote/missing..HEAD") == nil)
    }

    @Test("getAheadBehind counts both sides of leading-dash ranges")
    func aheadBehind() async throws {
        let (repository, base, _, _) = try await setupHistory()
        try await runGit(repository, ["checkout", "-b", "other", base])
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "side.txt", contents: "side\n")]))
        #expect(try await getAheadBehind(repository, "--remote/main...HEAD") == AheadBehind(ahead: 2, behind: 1))
        #expect(try await getAheadBehind(repository, "--remote/missing...HEAD") == nil)
    }

    @Test("getCommits reads refs and ranges while preserving filters and pagination")
    func commits() async throws {
        let (repository, base, first, tip) = try await setupHistory()
        let commits = try await getCommits(repository, "--remote/main")
        #expect(commits.map(\.sha) == [tip, first, base])
        let filtered = try await getCommits(
            repository,
            "--remote/base..--remote/main",
            limit: 1,
            skip: 1,
            additionalArgs: ["--grep=matching"]
        )
        #expect(filtered.map { CommitOneLine(sha: $0.sha, summary: $0.summary) } == [
            CommitOneLine(sha: first, summary: "matching first"),
        ])
        #expect(try await getCommits(repository, "--remote/main", additionalArgs: ["--grep=absent"]).isEmpty)
    }
}

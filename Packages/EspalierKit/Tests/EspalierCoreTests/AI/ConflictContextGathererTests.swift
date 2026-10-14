// Ported from the `resolveWithin` cases of
// desktop/app/test/unit/path-test.ts. The rest covers conflict labels, file
// reads, commit context, and pull request resolution.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Synchronization
import Testing
import TestSupport

/// A commit with `summary` and `body`.
private func makeCommit(_ summary: String, _ body: String = "") -> Commit {
    let author = CommitIdentity(name: "A", email: "a@example.com", date: Date(timeIntervalSince1970: 0))
    let sha = String(repeating: "0", count: 40 - String(summary.count, radix: 16).count) + String(summary.count, radix: 16)
    return Commit(
        sha: sha,
        shortSha: String(sha.suffix(7)),
        summary: summary,
        body: body,
        author: author,
        committer: author,
        parentSHAs: [],
        trailers: [],
        tags: []
    )
}

/// A pull request numbered `number`.
private func makePullRequest(_ number: Int, title: String? = nil, body: String = "") -> PullRequest {
    let repository = gitHubRepoFixture(owner: "owner", name: "repo")
    let ref = PullRequestRef(ref: "feature", sha: "sha", gitHubRepository: repository)
    return PullRequest(
        created: Date(timeIntervalSince1970: 0),
        title: title ?? "PR \(number)",
        pullRequestNumber: number,
        head: ref,
        base: ref,
        author: "someone",
        draft: false,
        body: body
    )
}

@Suite("resolveWithin")
struct ResolveWithinTests {
    @Test("fails for paths outside of the root")
    func outside() throws {
        let root = try createTempDirectory()
        #expect(try ConflictContextGatherer.resolveWithin(root, "..") == nil)
        #expect(try ConflictContextGatherer.resolveWithin(root, POSIXPath.join("..", "..")) == nil)
    }

    @Test("succeeds for paths that traverse out, and then back into, the root")
    func outAndBack() throws {
        let root = try createTempDirectory()
        #expect(try ConflictContextGatherer.resolveWithin(root, POSIXPath.join("..", POSIXPath.basename(root))) == root)
    }

    @Test("fails for paths containing null bytes")
    func nullBytes() throws {
        let root = try createTempDirectory()
        #expect(try ConflictContextGatherer.resolveWithin(root, "foo\u{0}bar") == nil)
    }

    @Test("succeeds for absolute relative paths as long as they stay within the root")
    func absolute() throws {
        let root = try createTempDirectory()
        let parent = POSIXPath.resolve(root, "..")
        #expect(try ConflictContextGatherer.resolveWithin(parent, root) == root)
    }

    @Test("fails for paths that use a symlink to traverse outside of the root")
    func symlinkOutside() throws {
        let tempDir = try createTempDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: POSIXPath.join(tempDir, "dangerzone"),
            withDestinationPath: POSIXPath.resolve(tempDir, "..", "..")
        )
        #expect(try ConflictContextGatherer.resolveWithin(tempDir, "dangerzone") == nil)
    }

    @Test("succeeds for paths that use a symlink to traverse outside of the root and then back again")
    func symlinkOutAndBack() throws {
        let tempDir = try createTempDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: POSIXPath.join(tempDir, "dangerzone"),
            withDestinationPath: POSIXPath.resolve(tempDir, "..", "..")
        )
        let throughSymlinkPath = POSIXPath.join(
            "dangerzone",
            POSIXPath.basename(POSIXPath.resolve(tempDir, "..")),
            POSIXPath.basename(tempDir)
        )
        #expect(try ConflictContextGatherer.resolveWithin(tempDir, throughSymlinkPath) == POSIXPath.resolve(tempDir, throughSymlinkPath))
    }

    @Test("fails for a sibling whose path starts with the root's (desktop's startsWith passed it)")
    func siblingPrefix() throws {
        let parent = try createTempDirectory()
        let root = POSIXPath.join(parent, "app")
        let sibling = POSIXPath.join(parent, "app-other")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: URL(filePath: POSIXPath.join(sibling, "secret.txt")))
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(root, "link"), withDestinationPath: sibling)

        #expect(try ConflictContextGatherer.resolveWithin(root, "link/secret.txt") == nil)
        #expect(ConflictContextGatherer.isWithin("/src/app/file", "/src/app"))
        #expect(ConflictContextGatherer.isWithin("/src/app", "/src/app"))
        #expect(!ConflictContextGatherer.isWithin("/src/app-other/file", "/src/app"))
        #expect(ConflictContextGatherer.isWithin("/anything", "/"))
    }

    @Test("throws for a path that doesn't exist, as Node's realpath does")
    func missing() throws {
        let root = try createTempDirectory()
        #expect(throws: (any Error).self) {
            try ConflictContextGatherer.resolveWithin(root, "missing.txt")
        }
    }
}

@Suite("Conflict context")
struct ConflictContextGathererTests {
    @Test("labels both sides as desktop does, with the branches D1 shows")
    func labels() {
        typealias Labels = ConflictContextGatherer.Labels
        let merge = ConflictState.merge(currentBranch: "main", currentTip: "a", manualResolutions: [:])
        #expect(ConflictContextGatherer.labels(merge, operation: nil, branches: ConflictBranches(ours: "main", theirs: "feature"))
            == Labels(ourLabel: "main", theirLabel: "feature", ourRef: "main", theirRef: "feature"))

        let rebase = ConflictState.rebase(
            currentTip: "b", targetBranch: "feature", baseBranch: nil, originalBranchTip: "c", baseBranchTip: "d", manualResolutions: [:]
        )
        // The base branch, when known, gives the rebase's side commit context.
        #expect(ConflictContextGatherer.labels(rebase, operation: nil, branches: ConflictBranches(ours: "main", theirs: "feature"))
            == Labels(ourLabel: "main", theirLabel: "feature", ourRef: "main", theirRef: "feature"))

        let squash = MultiCommitOperation(
            kind: .squash,
            detail: .squash(
                commits: [],
                currentTip: "b",
                lastRetainedCommitRef: nil,
                targetCommit: makeCommit("Target"),
                commitContext: CommitContext(summary: "Squashed", description: nil)
            ),
            phase: .conflicted,
            origin: .espalier
        )
        #expect(ConflictContextGatherer.labels(rebase, operation: squash, branches: ConflictBranches(ours: "feature", theirs: "squash commit"))
            == Labels(ourLabel: "feature", theirLabel: "squash commit", ourRef: nil, theirRef: nil))
    }

    @Test("names a rebase's unknown base by the commit it's being rebased onto")
    func rebaseOntoUnknownBase() {
        let rebase = ConflictState.rebase(
            currentTip: "b",
            targetBranch: "feature",
            baseBranch: nil,
            originalBranchTip: "c",
            baseBranchTip: "0123456789abcdef0123456789abcdef01234567",
            manualResolutions: [:]
        )
        #expect(ConflictContextGatherer.labels(rebase, operation: nil, branches: ConflictBranches(ours: nil, theirs: "feature"))
            == ConflictContextGatherer.Labels(ourLabel: "0123456", theirLabel: "feature", ourRef: nil, theirRef: "feature"))
    }

    @Test("reads text files, and leaves out those too large, unreadable, outside, or not UTF-8")
    func readsFiles() async throws {
        let root = try createTempDirectory()
        try Data("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n".utf8).write(to: URL(filePath: POSIXPath.join(root, "text.txt")))
        // Latin-1 text with conflict markers: writing a resolution back as
        // UTF-8 would change its other bytes.
        try (Data("<<<<<<< HEAD\n".utf8) + Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) + Data("=======\ncafe\n>>>>>>> feature\n".utf8))
            .write(to: URL(filePath: POSIXPath.join(root, "latin1.txt")))
        // A binary file has no markers; it's skipped for that.
        try Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00]).write(to: URL(filePath: POSIXPath.join(root, "image.png")))
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(root, "outside.txt"), withDestinationPath: "/etc/hosts")
        let large = POSIXPath.join(root, "large.bin")
        FileManager.default.createFile(atPath: large, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: large))
        try handle.truncate(atOffset: UInt64(MaxConflictFileReadSize) + 1)
        try handle.close()

        let entry = TextConflictEntry(action: .bothModified)
        func conflicted(_ path: String) -> WorkingDirectoryFileChange {
            WorkingDirectoryFileChange(
                path: path,
                status: .conflicted(.conflictsWithMarkers(entry: entry, conflictMarkerCount: 3)),
                selection: DiffSelection.fromInitialSelection(.all)
            )
        }
        let deleted = WorkingDirectoryFileChange(
            path: "deleted.txt",
            status: .conflicted(.manualConflict(entry: ManualConflictEntry(action: .deletedByThem))),
            selection: DiffSelection.fromInitialSelection(.all)
        )

        let files = await ConflictContextGatherer.readConflictedFiles(
            repositoryPath: root,
            files: ["text.txt", "latin1.txt", "image.png", "outside.txt", "large.bin", "missing.txt"].map(conflicted) + [deleted]
        )

        #expect(files == [
            ConflictedFile(path: "text.txt", contents: .text("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n")),
            ConflictedFile(path: "latin1.txt", contents: .unreadable),
            ConflictedFile(path: "image.png", contents: .text(String(decoding: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00]), as: UTF8.self))),
            ConflictedFile(path: "outside.txt", contents: .outsideRepository),
            ConflictedFile(path: "large.bin", contents: .tooLarge),
            ConflictedFile(path: "missing.txt", contents: .unresolvablePath),
            ConflictedFile(path: "deleted.txt", deletedSide: .theirs),
        ])
        #expect(ConflictContextGatherer.getDeletedSideFromStatus(deleted) == .theirs)
        #expect(ConflictContextGatherer.getDeletedSideFromStatus(conflicted("text.txt")) == nil)
    }

    @Test("resolves pull requests: the seeded one, then the cache, then the API, at most ten lookups")
    func pullRequests() async {
        let seeded = ConflictContextPullRequest(number: 1, title: "Current", body: "Mine")
        let fetched = Mutex<[Int]>([])
        let resolved = await ConflictContextGatherer.resolvePullRequestContexts(
            numbers: [1] + Array(2...14),
            seeded: [1: seeded],
            isGitHubRepository: true,
            cached: [makePullRequest(2, title: "Cached", body: "From the cache"), makePullRequest(14)],
            fetch: { number in
                fetched.withLock { $0.append(number) }
                return number == 3 ? ConflictContextPullRequest(number: 3, title: "Fetched", body: "") : nil
            }
        )

        #expect(resolved[1] == seeded)
        #expect(resolved[2] == ConflictContextPullRequest(number: 2, title: "Cached", body: "From the cache"))
        #expect(resolved[3] == ConflictContextPullRequest(number: 3, title: "Fetched", body: ""))
        // Only the first ten numbers that need looking up are looked up.
        #expect(resolved[14] == nil)
        #expect(fetched.withLock { $0 }.sorted() == Array(3...11))

        // Not a GitHub repository: only the seeded pull request.
        let local = await ConflictContextGatherer.resolvePullRequestContexts(
            numbers: [1, 2],
            seeded: [1: seeded],
            isGitHubRepository: false,
            cached: [makePullRequest(2)],
            fetch: { _ in nil }
        )
        #expect(local == [1: seeded])
    }

    @Test("fetches a missing pull request from the repository pull requests are contributed to")
    func fetchesFromAPI() async throws {
        let gitHub = MockGitHub()
        gitHub.on("GET", "/repos/upstream/hello/pulls/34", respond: .json([
            "number": 34, "title": "Merged work", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
            "user": .null, "body": .null, "state": "closed", "draft": false,
            "head": ["ref": "feature", "sha": "abc", "repo": .null],
            "base": ["ref": "main", "sha": "def", "repo": .null],
        ]))
        let account = Account(
            login: "octocat", endpoint: "https://api.github.com", token: "gho_token", emails: [], avatarURL: "",
            id: 1, name: "Octocat", plan: "free", clientID: nil
        )
        let fetch = ConflictContextGatherer.pullRequestFetcher(
            account: account,
            repository: gitHubRepoFixture(owner: "upstream", name: "hello"),
            runtime: gitHub.runtime
        )

        #expect(await fetch(34) == ConflictContextPullRequest(number: 34, title: "Merged work", body: ""))
        #expect(await fetch(35) == nil)
        #expect(gitHub.requests("GET", "/repos/upstream/hello/pulls/34").first?.header("Authorization") == "Bearer gho_token")
    }

    @Test("gathers each side's commits since the merge base, and the pull requests they mention")
    func gathers() async throws {
        let repository = try setupEmptyRepository("main")
        try await commit(["file.txt": "base\n"], "Initial commit", in: repository)
        try await runGit(["branch", "feature"], repository)
        try await commit(["file.txt": "main\n"], "Main side (#21)", in: repository)
        try await runGit(["checkout", "-q", "feature"], repository)
        try await commit(["file.txt": "feature\n"], "Feature side", in: repository)
        try await commit(["other.txt": "more\n"], "More feature work", in: repository)
        try await runGit(["checkout", "-q", "main"], repository)
        let mergeResult = try await Dugite.exec(["merge", "feature"], repository.path)
        #expect(mergeResult.exitCode == 1)
        let status = try #require(try await getStatus(repository))
        let conflicted = status.workingDirectory.files.filter { $0.status.kind == .conflicted }
        let featureTip = JSCompat.trim(try await runGit(["rev-parse", "feature"], repository))

        let (context, labels) = await ConflictContextGatherer.gather(ConflictContextGatherer.Input(
            repository: repository,
            conflictState: .merge(currentBranch: "main", currentTip: status.currentTip ?? "", manualResolutions: [:]),
            labels: ConflictContextGatherer.Labels(ourLabel: "main", theirLabel: "incoming branch", ourRef: "main", theirRef: nil),
            files: conflicted,
            localCommitSHAs: [featureTip],
            currentPullRequest: ConflictContextPullRequest(number: 5, title: "This branch", body: ""),
            isGitHubRepository: true,
            cachedPullRequests: [makePullRequest(21, title: "Main's change")],
            fetchPullRequest: nil
        ))

        // The merged branch, from MERGE_HEAD, when it wasn't known.
        #expect(labels.theirLabel == "feature")
        #expect(context.ourLabel == "main")
        #expect(context.theirLabel == "feature")
        #expect(context.files.map(\.path) == ["file.txt"])
        #expect(context.files.first?.hunks.first?.oursContent == "main")
        #expect(context.files.first?.hunks.first?.theirsContent == "feature")
        #expect(context.ourCommits.map(\.summary) == ["Main side (#21)"])
        #expect(context.theirCommits.map(\.summary) == ["More feature work", "Feature side"])
        #expect(context.theirCommits.first?.isOnRemote == false)
        #expect(context.ourCommits.first?.isOnRemote == true)
        #expect(context.pullRequests.map(\.number) == [5, 21])
        #expect(context.pullRequests.last?.title == "Main's change")
    }
}

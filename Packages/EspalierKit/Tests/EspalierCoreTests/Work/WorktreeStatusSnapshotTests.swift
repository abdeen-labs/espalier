// What a status's snapshot holds, when its changed files' fingerprint
// differs, and what two snapshots tell happened in between: on real
// repositories.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A worktree's snapshot, on `main`, one commit behind `origin/main`, with
/// changed files.
private let earlier = WorktreeStatusSnapshot(tip: "aaa", branch: "main", upstream: "origin/main", behind: 1, changedFiles: "f1")

/// `earlier` with `change` made to it.
private func later(_ change: (inout WorktreeStatusSnapshot) -> Void) -> WorktreeStatusSnapshot {
    var snapshot = earlier
    change(&snapshot)
    return snapshot
}

@Suite("Worktree status snapshot")
struct WorktreeStatusSnapshotTests {
    /// The snapshot of the repository's status now.
    private func snapshot(_ repository: Repository, gitDirectory: String? = nil) async throws -> WorktreeStatusSnapshot {
        await WorktreeStatusSnapshot.load(
            try await getStatusOrThrow(repository),
            workingDirectory: repository.path,
            gitDirectory: gitDirectory
        )
    }

    private func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func write(_ path: String, _ contents: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(exactFilePath: fullPath))
    }

    /// A repository with `README.md` and `notes.txt` committed, ignoring
    /// `build/`.
    private func committedRepository() async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [
            TreeEntry(path: "README.md", contents: "# README\n"),
            TreeEntry(path: "notes.txt", contents: "notes\n"),
            TreeEntry(path: ".gitignore", contents: "build/\n"),
        ]))
        return repository
    }

    @Test("a worktree last changed at the latest of its changed files' modification times and its HEAD's last move, in the main worktree and a linked one")
    func lastChanged() async throws {
        let repository = try await committedRepository()
        let linkedPath = realPath(POSIXPath.join(try createTempDirectory(), "linked"))
        _ = try await runGit(["worktree", "add", "-q", "-b", "linked", linkedPath], repository)
        let linked = Repository(path: linkedPath)
        let mainGitDirectory = POSIXPath.join(repository.path, ".git")
        let linkedGitDirectory = try await runGit(["rev-parse", "--absolute-git-dir"], linked)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(linkedGitDirectory != mainGitDirectory)
        let mainMoved = Date(timeIntervalSince1970: 1_700_000_000)
        let linkedMoved = mainMoved.addingTimeInterval(100)
        try setModified(POSIXPath.join(mainGitDirectory, "logs/HEAD"), mainMoved)
        try setModified(POSIXPath.join(linkedGitDirectory, "logs/HEAD"), linkedMoved)

        // No changed files: when HEAD last moved, each worktree's own.
        #expect(try await snapshot(repository, gitDirectory: mainGitDirectory).lastChanged == mainMoved)
        #expect(try await snapshot(linked, gitDirectory: linkedGitDirectory).lastChanged == linkedMoved)

        // A changed file written later.
        try write("notes.txt", "more notes\n", in: repository)
        let written = mainMoved.addingTimeInterval(200)
        try setModified(POSIXPath.join(repository.path, "notes.txt"), written)
        #expect(try await snapshot(repository, gitDirectory: mainGitDirectory).lastChanged == written)
        #expect(try await snapshot(linked, gitDirectory: linkedGitDirectory).lastChanged == linkedMoved)

        // A changed file written before HEAD moved.
        let earlier = mainMoved.addingTimeInterval(-500)
        try setModified(POSIXPath.join(repository.path, "notes.txt"), earlier)
        #expect(try await snapshot(repository, gitDirectory: mainGitDirectory).lastChanged == mainMoved)
        // Without the git directory, the files alone.
        #expect(try await snapshot(repository).lastChanged == earlier)

        // A deleted file has no time.
        try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "notes.txt"))
        #expect(try await snapshot(repository).lastChanged == nil)
        #expect(try await snapshot(repository).changedFilesSample == [ChangedFileSample(path: "notes.txt", kind: .deleted)])
    }

    @Test("the fingerprint differs once a file becomes changed, is written again, changes status, or stops being changed")
    func fingerprintFollowsChangedFiles() async throws {
        let repository = try await committedRepository()
        let clean = try await snapshot(repository).changedFiles
        #expect(clean.isEmpty)

        try write("README.md", "# README\n\nMore.\n", in: repository)
        let modified = try await snapshot(repository).changedFiles
        #expect(modified != clean)

        // Written again, still modified.
        try write("README.md", "# README\n\nMore still.\n", in: repository)
        let writtenAgain = try await snapshot(repository).changedFiles
        #expect(writtenAgain != modified)

        // Another file becomes changed.
        try write("new.txt", "new\n", in: repository)
        let withNewFile = try await snapshot(repository).changedFiles
        #expect(withNewFile != writtenAgain)

        // The same path in another state: untracked, then added.
        try await runGit(["add", "new.txt"], repository)
        let added = try await snapshot(repository).changedFiles
        #expect(added != withNewFile)

        // A deleted file is changed too.
        try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "notes.txt"))
        let deleted = try await snapshot(repository).changedFiles
        #expect(deleted != added)

        // Nothing is changed once it's all committed.
        try await runGit(["add", "--all"], repository)
        try await runGit(["commit", "-m", "Everything"], repository)
        #expect(try await snapshot(repository).changedFiles.isEmpty)
    }

    @Test("an ignored file, a tracked file touched without a content change, and git rewriting the index leave the fingerprint as it is")
    func fingerprintIgnoresWhatStatusDoesNotList() async throws {
        let repository = try await committedRepository()
        try write("README.md", "# README\n\nMore.\n", in: repository)
        let before = try await snapshot(repository)
        #expect(!before.changedFiles.isEmpty)

        try write("build/output.o", "object\n", in: repository)
        #expect(try await snapshot(repository) == before)

        // Touched: a new modification time, the same contents.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)],
            ofItemAtPath: POSIXPath.join(repository.path, "notes.txt")
        )
        #expect(try await snapshot(repository) == before)

        // A status that takes the index's lock refreshes the touched file's
        // entry and writes the index.
        try await runGit(["status"], repository)
        #expect(try await snapshot(repository) == before)
    }

    @Test("the same files in the same state have the same fingerprint, whatever status made it")
    func fingerprintIsStable() async throws {
        let repository = try await committedRepository()
        try write("README.md", "# README\n\nMore.\n", in: repository)
        try write("new.txt", "new\n", in: repository)
        let first = try await snapshot(repository)
        let second = try await snapshot(repository)
        #expect(first == second)
    }

    @Test("holds the tip, the branch, its upstream, and how far behind it is")
    func headAndUpstream() async throws {
        let unborn = try setupEmptyRepository()
        #expect(try await snapshot(unborn) == WorktreeStatusSnapshot(tip: nil, branch: "master"))

        let (local, remote) = try await setupRepositoryWithRemote()
        let tip = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
        #expect(try await snapshot(local) == WorktreeStatusSnapshot(tip: tip, branch: "main", upstream: "origin/main", behind: 0))

        try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
        try await runGit(["fetch", "-q", "origin"], local)
        #expect(try await snapshot(local) == WorktreeStatusSnapshot(tip: tip, branch: "main", upstream: "origin/main", behind: 1))

        try await runGit(["checkout", "-q", "--detach"], local)
        #expect(try await snapshot(local) == WorktreeStatusSnapshot(tip: tip, branch: nil))
    }

    @Test("tells what happened between two snapshots", arguments: [
        NamedCase("nothing, for the same snapshot", (later { _ in }, [])),
        NamedCase("files, when the fingerprint differs", (later { $0.changedFiles = "f2" }, [.files])),
        NamedCase("head, when the tip commit differs", (later { $0.tip = "bbb" }, [.head])),
        NamedCase("head, when the branch differs at the same commit", (later { $0.branch = "other"; $0.upstream = nil; $0.behind = nil }, [.head])),
        NamedCase("head, when HEAD is detached at the same commit", (later { $0.branch = nil; $0.upstream = nil; $0.behind = nil }, [.head])),
        NamedCase("server, when the branch is further behind its upstream", (later { $0.behind = 3 }, [.server])),
        NamedCase("nothing, when the branch is less far behind", (later { $0.behind = 0 }, [])),
        NamedCase("head alone, when another branch is further behind", (later { $0.branch = "other"; $0.behind = 5 }, [.head])),
        NamedCase("nothing, when the branch is further behind another upstream", (later { $0.upstream = "fork/main"; $0.behind = 5 }, [])),
        NamedCase("head and files, when a commit took the changed files", (later { $0.tip = "bbb"; $0.changedFiles = "" }, [.head, .files])),
    ] as [NamedCase<(WorktreeStatusSnapshot, Set<WorktreeActivityKind>)>])
    func activitySince(_ testCase: NamedCase<(WorktreeStatusSnapshot, Set<WorktreeActivityKind>)>) {
        let (snapshot, expected) = testCase.value
        #expect(snapshot.activity(since: earlier) == expected)
    }

    @Test("a branch that gets an upstream isn't further behind it")
    func firstUpstream() {
        let before = WorktreeStatusSnapshot(tip: "aaa", branch: "main")
        let after = WorktreeStatusSnapshot(tip: "aaa", branch: "main", upstream: "origin/main", behind: 4)
        #expect(after.activity(since: before).isEmpty)
    }
}

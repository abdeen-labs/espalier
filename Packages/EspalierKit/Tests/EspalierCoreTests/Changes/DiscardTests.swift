// Discarding changes: the Trash and permanent paths, a failing Trash,
// renames, copies, submodules, items in the way of restored files, files
// git doesn't restore, the confirmations, and discarding lines.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// A Trash that fails from its `failFrom`th move on (0-based), recording
/// what it moved.
private final class FlakyTrash: TrashService {
    private let state = Mutex<(moves: Int, trashed: [String])>((0, []))
    private let failFrom: Int
    private let directory: String

    init(failFrom: Int) throws {
        self.failFrom = failFrom
        directory = try createTempDirectory(prefix: "espalier-trash-")
    }

    var trashedPaths: [String] {
        state.withLock { $0.trashed }
    }

    func moveToTrash(_ path: String) async throws {
        let move = state.withLock { state -> Int in
            defer { state.moves += 1 }
            return state.moves
        }
        if move >= failFrom {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        try FileManager.default.moveItem(atPath: path, toPath: POSIXPath.join(directory, UUID().uuidString))
        state.withLock { $0.trashed.append(path) }
    }
}

/// Writes `contents` to `path` in `repository`, making its folders.
private func writeFile(_ path: String, _ contents: String, in repository: Repository) throws {
    let fullPath = POSIXPath.join(repository.path, path)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(filePath: fullPath))
}

/// The contents of `path` in `repository`, or nil when there's no file.
private func readFile(_ path: String, in repository: Repository) -> String? {
    try? String(contentsOfFile: POSIXPath.join(repository.path, path), encoding: .utf8)
}

/// How the git side of a discard is run.
struct DiscardMode: Sendable {
    var moveToTrash: Bool
    var askBeforeDeleting: Bool
    var trashFails: Bool
}

/// The ways a discard deletes instead of using the Trash.
private let deletingModes: [NamedCase<DiscardMode>] = [
    NamedCase("discarding permanently", DiscardMode(moveToTrash: false, askBeforeDeleting: true, trashFails: false)),
    NamedCase("the Trash failing, deleting without asking", DiscardMode(moveToTrash: true, askBeforeDeleting: false, trashFails: true)),
]

/// The ways a discard can't move what's in the way to the Trash.
private let stoppingModes: [NamedCase<DiscardMode>] = [
    NamedCase("discarding permanently", DiscardMode(moveToTrash: false, askBeforeDeleting: true, trashFails: false)),
    NamedCase("the Trash failing, asking before deleting", DiscardMode(moveToTrash: true, askBeforeDeleting: true, trashFails: true)),
    NamedCase("the Trash failing, deleting without asking", DiscardMode(moveToTrash: true, askBeforeDeleting: false, trashFails: true)),
]

/// Something the user didn't discard in the way of restoring a discarded
/// file, in a repository where README.md is changed and notes.txt is
/// untracked too (`makeInTheWayRepository`).
struct InTheWayCase: Sendable {
    /// The file committed ("committed\n"), then changed by `setUp`.
    var committed: String
    /// Changes `committed` and makes what's in the way.
    var setUp: @Sendable (Repository) async throws -> Void
    /// The changed file discarded with README.md and notes.txt.
    var discarded: String
    /// The item in the way.
    var inTheWay: String
    /// A file in the way that keeps its contents when the discard stops.
    var kept: (path: String, contents: String)
    /// A file a link in the way points to, which stays when the link goes.
    var outside: (path: String, contents: String)?
}

private let inTheWayCases: [NamedCase<InTheWayCase>] = [
    NamedCase("a folder made where a deleted file was", InTheWayCase(
        committed: "config",
        setUp: { repository in
            try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "config"))
            try writeFile("config/default.json", "{}\n", in: repository)
        },
        discarded: "config",
        inTheWay: "config",
        kept: ("config/default.json", "{}\n")
    )),
    NamedCase("a file made where a deleted file's folder was", InTheWayCase(
        committed: "a/b",
        setUp: { repository in
            try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "a"))
            try writeFile("a", "mine\n", in: repository)
        },
        discarded: "a/b",
        inTheWay: "a",
        kept: ("a", "mine\n")
    )),
    NamedCase("a symbolic link made where a deleted file's folder was", InTheWayCase(
        committed: "d/e",
        setUp: { repository in
            try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "d"))
            try writeFile("real/keep", "keep\n", in: repository)
            try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(repository.path, "d"), withDestinationPath: "real")
        },
        discarded: "d/e",
        inTheWay: "d",
        // Read through the link, which is still there.
        kept: ("d/keep", "keep\n"),
        outside: ("real/keep", "keep\n")
    )),
    NamedCase("a file made where a renamed file's old folder was", InTheWayCase(
        committed: "a/b",
        setUp: { repository in
            try await runGit(["mv", "a/b", "c"], repository)
            // git leaves the emptied folder.
            if itemExists(atPath: POSIXPath.join(repository.path, "a")) {
                try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "a"))
            }
            try writeFile("a", "mine\n", in: repository)
        },
        discarded: "c",
        inTheWay: "a",
        kept: ("a", "mine\n")
    )),
]

/// The repository `scenario` describes, and the changes to discard:
/// README.md, notes.txt, and `scenario.discarded`.
private func makeInTheWayRepository(_ scenario: InTheWayCase) async throws -> (Repository, [WorkingDirectoryFileChange]) {
    let (local, _) = try await setupRepositoryWithRemote()
    try writeFile(scenario.committed, "committed\n", in: local)
    try await runGit(["add", "--", scenario.committed], local)
    try await runGit(["commit", "-q", "-m", "Commit"], local)
    try await scenario.setUp(local)
    try writeFile("README.md", "# Changed\n", in: local)
    try writeFile("notes.txt", "notes\n", in: local)

    let changed = try await getStatusOrThrow(local).workingDirectory.files
    var files: [WorkingDirectoryFileChange] = []
    for path in ["README.md", "notes.txt", scenario.discarded] {
        files.append(try #require(changed.first { $0.path == path }, "No changed file \(path)"))
    }
    return (local, files)
}

/// Changes whose paths git doesn't restore from HEAD, discarded without
/// the Trash.
struct UnrestoredCase: Sendable {
    /// The repository with the changes.
    var make: @Sendable () async throws -> Repository
    /// The paths of the changes discarded; nil for all of them.
    var discarding: [String]?
    /// The paths with nothing at them afterwards.
    var gone: [String]
    /// Files' contents afterwards.
    var contents: [String: String]
    /// The changed paths afterwards.
    var remaining: [String]
}

private let unrestoredCases: [NamedCase<UnrestoredCase>] = [
    NamedCase("a staged new file is deleted", UnrestoredCase(
        make: {
            let (local, _) = try await setupRepositoryWithRemote()
            try writeFile("notes.txt", "notes\n", in: local)
            try await runGit(["add", "notes.txt"], local)
            return local
        },
        gone: ["notes.txt"],
        contents: ["README.md": "# README\n"],
        remaining: []
    )),
    NamedCase("a staged rename's new path is deleted and its old path restored", UnrestoredCase(
        make: {
            let (local, _) = try await setupRepositoryWithRemote()
            try await runGit(["mv", "README.md", "NEW.md"], local)
            return local
        },
        gone: ["NEW.md"],
        contents: ["README.md": "# README\n"],
        remaining: []
    )),
    NamedCase("a staged copy is deleted, and its source keeps its changes", UnrestoredCase(
        make: {
            let (local, _) = try await setupRepositoryWithRemote()
            try writeFile("source.txt", "one\ntwo\nthree\nfour\nfive\n", in: local)
            try await runGit(["add", "source.txt"], local)
            try await runGit(["commit", "-q", "-m", "Source"], local)
            try await runGit(["config", "status.renames", "copies"], local)
            try writeFile("copy.txt", "one\ntwo\nthree\nfour\nfive\n", in: local)
            try writeFile("source.txt", "one\ntwo\nthree\nfour\nfive\nsix\n", in: local)
            try await runGit(["add", "."], local)
            guard case .copied? = try await getStatusOrThrow(local).workingDirectory.files.first(where: { $0.path == "copy.txt" })?.status else {
                throw TestSupportError("copy.txt isn't a copy")
            }
            return local
        },
        discarding: ["copy.txt"],
        gone: ["copy.txt"],
        contents: ["source.txt": "one\ntwo\nthree\nfour\nfive\nsix\n"],
        remaining: ["source.txt"]
    )),
    // On other-branch, merging master: "modified" both modified, "added"
    // both added, and "gone" deleted by us (HEAD) and changed by them.
    NamedCase("conflicted files go back to HEAD's version, and one HEAD doesn't have is deleted", UnrestoredCase(
        make: {
            let repository = try setupEmptyRepository()
            try await makeCommit(repository, Tree(entries: [
                TreeEntry(path: "modified", contents: "base\n"),
                TreeEntry(path: "gone", contents: "base\n"),
            ]))
            _ = try await Dugite.exec(["branch", "other-branch"], repository.path)
            try await makeCommit(repository, Tree(entries: [
                TreeEntry(path: "modified", contents: "theirs\n"),
                TreeEntry(path: "gone", contents: "theirs\n"),
                TreeEntry(path: "added", contents: "theirs\n"),
            ]))
            try await switchTo(repository, "other-branch")
            try await makeCommit(repository, Tree(entries: [
                TreeEntry(path: "modified", contents: "ours\n"),
                TreeEntry(path: "gone", contents: nil),
                TreeEntry(path: "added", contents: "ours\n"),
            ]))
            _ = try await Dugite.exec(["merge", "master"], repository.path)
            let conflicts = try await getStatusOrThrow(repository).workingDirectory.files.compactMap { file -> String? in
                guard case .conflicted(let conflict) = file.status else {
                    return nil
                }
                return "\(file.path) \(conflict.entry.action.rawValue)"
            }
            guard conflicts.sorted() == ["added both-added", "gone deleted-by-us", "modified both-modified"] else {
                throw TestSupportError("Unexpected conflicts \(conflicts)")
            }
            return repository
        },
        gone: ["gone"],
        contents: ["modified": "ours\n", "added": "ours\n"],
        remaining: []
    )),
]

@Suite("Discarding changes", .offline) @MainActor
struct DiscardTests {
    private let everything: Set<ConfirmationKind> = [.discardChanges, .discardAllChanges]

    /// A selected repository with README.md committed ("# README"), then
    /// modified, and an untracked notes.txt.
    private func makeFixture() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("README.md", "# Changed\n")
        try fixture.write("notes.txt", "notes\n")
        await fixture.refresh()
        return fixture
    }

    // MARK: Files

    @Test("moves the working copies to the Trash and restores tracked files")
    func toTrash() async throws {
        let fixture = try await makeFixture()
        try await fixture.changes.discard(fixture.changes.workingDirectory.files, confirmed: everything)

        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        #expect(!fixture.exists("notes.txt"))
        let trashed = fixture.harness.trash.trashedPaths.map { POSIXPath.basename($0) }
        #expect(trashed.sorted() == ["README.md", "notes.txt"])
        await fixture.settle()
    }

    @Test("discarding permanently deletes untracked files and lets git restore tracked ones")
    func permanently() async throws {
        let fixture = try await makeFixture()
        try await fixture.changes.discard(fixture.changes.workingDirectory.files, permanently: true, confirmed: everything)

        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        #expect(!fixture.exists("notes.txt"))
        #expect(fixture.harness.trash.trashedPaths.isEmpty)
        await fixture.settle()
    }

    @Test("asks for one file per the preference, for several always, and for all of them as discarding everything")
    func confirmations() async throws {
        let fixture = try await makeFixture()
        let readme = try fixture.file("README.md")
        let notes = try fixture.file("notes.txt")

        let one = await #expect(throws: OperationError.self) {
            try await fixture.changes.discard([readme])
        }
        let oneConfirmation = try #require(confirmation(of: one))
        #expect(oneConfirmation.kind == .discardChanges)
        #expect(oneConfirmation.details == .files(["README.md"]))

        let all = await #expect(throws: OperationError.self) {
            try await fixture.changes.discard([readme, notes], confirmed: [.discardChanges])
        }
        #expect(confirmationKind(of: all) == .discardAllChanges)
        #expect(fixture.read("README.md") == "# Changed\n")

        // Without the preference one file goes at once; several still ask.
        fixture.app.preferences.confirmDiscardChanges = false
        try fixture.write("other.txt", "other\n")
        await fixture.refresh()
        let several = await #expect(throws: OperationError.self) {
            try await fixture.changes.discard([try fixture.file("notes.txt"), try fixture.file("other.txt")])
        }
        #expect(confirmationKind(of: several) == .discardChanges)

        try await fixture.changes.discard([try fixture.file("README.md")])
        #expect(fixture.paths == ["notes.txt", "other.txt"])
        await fixture.settle()
    }

    @Test("Discard All Changes always asks, for one file too and with the preference off, as desktop")
    func discardAllAlwaysAsks() async throws {
        let fixture = try await makeFixture()
        try await runGit(["add", "notes.txt"], fixture.local)
        try await runGit(["commit", "-q", "-m", "Notes"], fixture.local)
        await fixture.refresh()
        #expect(fixture.paths == ["README.md"])

        for confirmsDiscarding in [false, true] {
            fixture.app.preferences.confirmDiscardChanges = confirmsDiscarding
            let one = await #expect(throws: OperationError.self) {
                try await fixture.changes.discardAllChanges(fixture.changes.workingDirectory.files)
            }
            let asked = try #require(confirmation(of: one))
            #expect(asked.kind == .discardAllChanges)
            #expect(asked.details == .files(["README.md"]))
            // Confirming the single file's question isn't enough.
            let other = await #expect(throws: OperationError.self) {
                try await fixture.changes.discardAllChanges(fixture.changes.workingDirectory.files, confirmed: [.discardChanges])
            }
            #expect(confirmationKind(of: other) == .discardAllChanges)
            #expect(fixture.read("README.md") == "# Changed\n")
        }

        // Several files, the preference off: asks as well.
        fixture.app.preferences.confirmDiscardChanges = false
        try fixture.write("notes.txt", "more notes\n")
        try fixture.write("other.txt", "other\n")
        await fixture.refresh()
        let several = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardAllChanges(fixture.changes.workingDirectory.files)
        }
        #expect(confirmationKind(of: several) == .discardAllChanges)
        guard case .files(let listed)? = confirmation(of: several)?.details else {
            Issue.record("No files listed")
            return
        }
        #expect(listed.sorted() == ["README.md", "notes.txt", "other.txt"])

        // Confirmed, it discards them all.
        try await fixture.changes.discardAllChanges(fixture.changes.workingDirectory.files, confirmed: [.discardAllChanges])
        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        #expect(fixture.read("notes.txt") == "notes\n")
        #expect(!fixture.exists("other.txt"))
        await fixture.settle()
    }

    @Test("a failing Trash asks to discard permanently, and the recovery does")
    func trashFails() async throws {
        let fixture = try await makeFixture()
        fixture.harness.trash.setFailing(true)
        let files = fixture.changes.workingDirectory.files

        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discard(files, confirmed: everything)
        }
        #expect(error?.reason == .trashFailed(files: files))
        #expect(error?.retry?.kind == .discardChanges)
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .discardPermanently)
        #expect(recovery.isHeadless)
        await fixture.settle()
        // Nothing was discarded yet.
        #expect(fixture.read("README.md") == "# Changed\n")
        #expect(fixture.exists("notes.txt"))

        try await recovery.perform(in: fixture.app)
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        #expect(!fixture.exists("notes.txt"))
    }

    @Test("with asking turned off, a failing Trash deletes untracked files and git restores tracked ones")
    func trashFailsWithoutAsking() async throws {
        let fixture = try await makeFixture()
        fixture.app.preferences.confirmDiscardChangesPermanently = false
        fixture.harness.trash.setFailing(true)

        try await fixture.changes.discard(fixture.changes.workingDirectory.files, confirmed: everything)
        #expect(fixture.paths.isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        #expect(!fixture.exists("notes.txt"))
        await fixture.settle()
    }

    @Test("when the Trash fails partway, the files already in the Trash are finished and only the rest wait")
    func trashFailsPartway() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("# Changed\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
        try Data("a\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "a.txt")))
        try Data("b\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "b.txt")))
        // In the list's order.
        let files = try await getStatusOrThrow(local).workingDirectory.files
            .sorted { JSCompat.caseInsensitiveCompare($0.path, $1.path) < 0 }
        #expect(files.map(\.path) == ["a.txt", "b.txt", "README.md"])
        let trash = try FlakyTrash(failFrom: 2)

        let failure = await #expect(throws: TrashFailedError.self) {
            try await discardChanges(files, in: local, moveToTrash: true, askBeforeDeleting: true, trash: trash)
        }
        #expect(failure?.files.map(\.path) == ["README.md"])
        #expect(trash.trashedPaths.map { POSIXPath.basename($0) } == ["a.txt", "b.txt"])
        let afterFailure = try await getStatusOrThrow(local).workingDirectory.files
        #expect(afterFailure.map(\.path) == ["README.md"])
        #expect(afterFailure.first?.status.kind == .modified)

        // The retry deletes what's left; files already gone aren't errors.
        try await discardChanges(files, in: local, moveToTrash: false, askBeforeDeleting: true, trash: trash)
        #expect(try await getStatusOrThrow(local).workingDirectory.files.isEmpty)
    }

    @Test("when the Trash fails partway, a deleted file whose folder holds a file not in the Trash yet waits too")
    func trashFailsPartwayWithFolder() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try writeFile("config", "committed\n", in: local)
        try await runGit(["add", "config"], local)
        try await runGit(["commit", "-q", "-m", "Config"], local)
        try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, "config"))
        try writeFile("config/default.json", "{}\n", in: local)
        let changed = try await getStatusOrThrow(local).workingDirectory.files
        // The deleted file first, so it's done when the Trash fails.
        var files: [WorkingDirectoryFileChange] = []
        for path in ["config", "config/default.json"] {
            files.append(try #require(changed.first { $0.path == path }, "No changed file \(path)"))
        }
        let trash = try TemporaryTrash()
        trash.setFailing(true)

        let failure = await #expect(throws: TrashFailedError.self) {
            try await discardChanges(files, in: local, moveToTrash: true, askBeforeDeleting: true, trash: trash)
        }
        #expect(failure?.files.map(\.path) == ["config", "config/default.json"])
        #expect(readFile("config/default.json", in: local) == "{}\n")

        // Discarding them permanently, as the recovery does.
        try await discardChanges(files, in: local, moveToTrash: false, askBeforeDeleting: true, trash: trash)
        #expect(readFile("config", in: local) == "committed\n")
        #expect(try await getStatusOrThrow(local).workingDirectory.files.isEmpty)
    }

    @Test("a file deleted since the list loaded isn't a failure")
    func alreadyGone() async throws {
        let fixture = try await makeFixture()
        let notes = try fixture.file("notes.txt")
        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "notes.txt"))
        try await fixture.changes.discard([notes], confirmed: everything)
        try await fixture.changes.discard([notes], permanently: true, confirmed: everything)
        #expect(fixture.paths == ["README.md"])
        await fixture.settle()
    }

    @Test("an untracked directory is never deleted recursively")
    func untrackedDirectory() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let directory = POSIXPath.join(local.path, "nested")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: URL(filePath: POSIXPath.join(directory, "keep.txt")))
        let file = WorkingDirectoryFileChange(path: "nested", status: .untracked(), selection: .fromInitialSelection(.all))

        await #expect(throws: POSIXError.self) {
            try await discardChanges([file], in: local, moveToTrash: false, askBeforeDeleting: true, trash: try TemporaryTrash())
        }
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(directory, "keep.txt")))
    }

    @Test("staged changes are reset before the files are restored")
    func stagedChanges() async throws {
        let fixture = try await makeFixture()
        try await fixture.git(["add", "README.md", "notes.txt"])
        await fixture.refresh()
        #expect(try fixture.file("notes.txt").status.kind == .new)

        try await fixture.changes.discard(fixture.changes.workingDirectory.files, confirmed: everything)
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        #expect(fixture.read("README.md") == "# README\n")
        await fixture.settle()
    }

    @Test("discarding a renamed file doesn't overwrite a file that's now at its old path")
    func renameWithFileAtOldPath() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.git(["mv", "README.md", "NEW.md"])
        try fixture.write("README.md", "mine\n")
        await fixture.refresh()
        let renamed = try fixture.file("NEW.md")
        #expect(renamed.status.kind == .renamed)
        #expect(try fixture.file("README.md").status.kind == .untracked)

        try await fixture.changes.discard([renamed], confirmed: everything)
        #expect(!fixture.exists("NEW.md"))
        #expect(fixture.read("README.md") == "mine\n")
        // The index has README.md again; the user's file shows as a change.
        #expect(fixture.paths == ["README.md"])
        #expect(try fixture.file("README.md").status.kind == .modified)
        await fixture.settle()
    }

    @Test("discarding a copy keeps the changes to its source")
    func copy() async throws {
        let path = try setupFixtureRepository("copy-detection-status")
        let repository = Repository(path: path)
        try await runGit(["config", "status.renames", "copies"], repository)
        try await runGit(["add", "."], repository)
        let contributing = try String(contentsOfFile: POSIXPath.join(path, "CONTRIBUTING.md"), encoding: .utf8)
        let fixture = try await ChangesFixture.make(repository)
        let copy = try fixture.file("docs/OVERVIEW.md")
        guard case .copied(let oldPath, _, _) = copy.status else {
            Issue.record("Expected a copy, got \(copy.status)")
            return
        }
        #expect(oldPath == "CONTRIBUTING.md")

        try await fixture.changes.discard([copy], confirmed: everything)
        #expect(!fixture.exists("docs/OVERVIEW.md"))
        #expect(fixture.read("CONTRIBUTING.md") == contributing)
        #expect(fixture.paths == ["CONTRIBUTING.md"])
        #expect(try fixture.file("CONTRIBUTING.md").status.kind == .modified)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"]) == "CONTRIBUTING.md\n")
        await fixture.settle()
    }

    @Test("discarding a submodule's change resets it to its recorded commit, without the Trash")
    func submodule() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let submodule = try await setupTwoCommitRepo()
        try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "sub"])
        try await fixture.git(["commit", "-m", "Add a submodule"])
        let subPath = POSIXPath.join(fixture.local.path, "sub")
        let recorded = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], Repository(path: subPath)))
        try await runGit(["checkout", "-q", "HEAD~1"], Repository(path: subPath))
        await fixture.refresh()
        let file = try fixture.file("sub")
        #expect(file.status.submoduleStatus?.commitChanged == true)

        try await fixture.changes.discard([file], confirmed: everything)
        #expect(fixture.paths.isEmpty)
        #expect(JSCompat.trim(try await runGit(["rev-parse", "HEAD"], Repository(path: subPath))) == recorded)
        #expect(fixture.harness.trash.trashedPaths.isEmpty)
        await fixture.settle()
    }

    // MARK: Items in the way

    @Test("with the Trash, an item in the way of a restored file goes to the Trash first, and everything is discarded", arguments: inTheWayCases)
    func inTheWayToTrash(_ testCase: NamedCase<InTheWayCase>) async throws {
        let scenario = testCase.value
        let (local, files) = try await makeInTheWayRepository(scenario)
        let trash = try TemporaryTrash()

        try await discardChanges(files, in: local, moveToTrash: true, askBeforeDeleting: true, trash: trash)
        #expect(trash.trashedPaths.first == POSIXPath.join(local.path, scenario.inTheWay))
        #expect(readFile(scenario.committed, in: local) == "committed\n")
        #expect(readFile("README.md", in: local) == "# README\n")
        #expect(!itemExists(atPath: POSIXPath.join(local.path, "notes.txt")))
        // A link's target stays where it is.
        let remaining = try await getStatusOrThrow(local).workingDirectory.files.map(\.path)
        #expect(remaining == (scenario.outside.map { [$0.path] } ?? []))
        if let outside = scenario.outside {
            #expect(readFile(outside.path, in: local) == outside.contents)
        }
    }

    @Test("an item in the way of a restored file stops the discard before anything changes", arguments: inTheWayCases, stoppingModes)
    func inTheWayStops(_ testCase: NamedCase<InTheWayCase>, _ mode: NamedCase<DiscardMode>) async throws {
        let scenario = testCase.value
        let (local, files) = try await makeInTheWayRepository(scenario)
        let before = try await runGit(["status", "--porcelain", "-uall"], local)
        let trash = try TemporaryTrash()
        trash.setFailing(mode.value.trashFails)

        let error = await #expect(throws: DiscardItemsInTheWayError.self) {
            try await discardChanges(
                files,
                in: local,
                moveToTrash: mode.value.moveToTrash,
                askBeforeDeleting: mode.value.askBeforeDeleting,
                trash: trash
            )
        }
        #expect(error?.paths == [scenario.inTheWay])
        #expect((error?.trashError != nil) == mode.value.trashFails)
        #expect(try await runGit(["status", "--porcelain", "-uall"], local) == before)
        #expect(readFile(scenario.kept.path, in: local) == scenario.kept.contents)
        #expect(readFile("README.md", in: local) == "# Changed\n")
        #expect(readFile("notes.txt", in: local) == "notes\n")
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test("a folder where a deleted file was isn't in the way when everything in it is discarded too", arguments: [
        NamedCase("with the Trash", true),
        NamedCase("discarding permanently", false),
    ])
    func folderOfDiscardedFiles(_ testCase: NamedCase<Bool>) async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try writeFile("config", "committed\n", in: local)
        try await runGit(["add", "config"], local)
        try await runGit(["commit", "-q", "-m", "Config"], local)
        try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, "config"))
        try writeFile("config/default.json", "{}\n", in: local)
        try writeFile("config/nested/more.json", "{}\n", in: local)
        try FileManager.default.createDirectory(atPath: POSIXPath.join(local.path, "config/empty"), withIntermediateDirectories: true)
        let files = try await getStatusOrThrow(local).workingDirectory.files
        #expect(files.map(\.path).sorted() == ["config", "config/default.json", "config/nested/more.json"])
        let trash = try TemporaryTrash()

        try await discardChanges(files, in: local, moveToTrash: testCase.value, askBeforeDeleting: true, trash: trash)
        #expect(readFile("config", in: local) == "committed\n")
        #expect(try await getStatusOrThrow(local).workingDirectory.files.isEmpty)
        // The files went to the Trash, not the folder.
        let trashed = trash.trashedPaths.map { POSIXPath.basename($0) }.sorted()
        #expect(trashed == (testCase.value ? ["default.json", "more.json"] : []))
    }

    @Test("discarding permanently with a folder in the way fails as a precondition, with nothing offered and nothing discarded")
    func inTheWayThroughTheModel() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("config", "committed\n")
        try await fixture.git(["add", "config"])
        try await fixture.git(["commit", "-m", "Config"])
        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "config"))
        try fixture.write("config/default.json", "{}\n")
        await fixture.refresh()
        let config = try fixture.file("config")
        #expect(config.status.kind == .deleted)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discard([config], permanently: true, confirmed: everything)
        }
        #expect(preconditionText(error) != nil)
        #expect(error?.recoveries.isEmpty == true)
        await fixture.settle()
        #expect(fixture.read("config/default.json") == "{}\n")
        #expect(fixture.paths.sorted() == ["config", "config/default.json"])
    }

    // MARK: Files git doesn't restore

    @Test("discarding permanently deletes the files git doesn't restore and restores the rest", arguments: unrestoredCases, deletingModes)
    func unrestored(_ testCase: NamedCase<UnrestoredCase>, _ mode: NamedCase<DiscardMode>) async throws {
        let scenario = testCase.value
        let local = try await scenario.make()
        let changed = try await getStatusOrThrow(local).workingDirectory.files
        let files = scenario.discarding.map { paths in changed.filter { paths.contains($0.path) } } ?? changed
        #expect(files.count == (scenario.discarding?.count ?? changed.count))
        let trash = try TemporaryTrash()
        trash.setFailing(mode.value.trashFails)

        try await discardChanges(
            files,
            in: local,
            moveToTrash: mode.value.moveToTrash,
            askBeforeDeleting: mode.value.askBeforeDeleting,
            trash: trash
        )
        for path in scenario.gone {
            #expect(!itemExists(atPath: POSIXPath.join(local.path, path)), "\(path) is still there")
        }
        for (path, contents) in scenario.contents {
            #expect(readFile(path, in: local) == contents, "\(path)")
        }
        #expect(try await getStatusOrThrow(local).workingDirectory.files.map(\.path) == scenario.remaining)
        #expect(trash.trashedPaths.isEmpty)
    }

    // MARK: Lines

    /// numbered.txt with 20 committed lines, then lines 2 and 15 changed;
    /// the file selected and its diff loaded.
    private func makeLinesFixture() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("numbered.txt", numberedLines(20))
        try await fixture.git(["add", "numbered.txt"])
        try await fixture.git(["commit", "-m", "Number the lines"])
        try fixture.write("numbered.txt", numberedLines(20, replacing: [2: "line two", 15: "line fifteen"]))
        await fixture.refresh(.full)
        try await fixture.select("numbered.txt")
        return fixture
    }

    @Test("discards an added line, a removed line, and a whole block of the working copy")
    func discardLines() async throws {
        let fixture = try await makeLinesFixture()

        try await fixture.changes.discardLines(.line(try fixture.lineIndex(.add, "line fifteen")), confirmed: [.discardLines])
        await fixture.settle()
        #expect(fixture.read("numbered.txt") == numberedLines(20, replacing: [2: "line two", 15: ""]).replacingOccurrences(of: "\n\n", with: "\n"))

        try await fixture.changes.discardLines(.line(try fixture.lineIndex(.delete, "line 15")), confirmed: [.discardLines])
        await fixture.settle()
        #expect(fixture.read("numbered.txt") == numberedLines(20, replacing: [2: "line two"]))

        try await fixture.changes.discardLines(.block(containing: try fixture.lineIndex(.add, "line two")), confirmed: [.discardLines])
        await fixture.settle()
        #expect(fixture.read("numbered.txt") == numberedLines(20))
        #expect(fixture.paths.isEmpty)
    }

    @Test("asks before discarding lines while the preference is on")
    func discardLinesConfirmation() async throws {
        let fixture = try await makeLinesFixture()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.hunk(containing: try fixture.lineIndex(.add, "line two")))
        }
        let asked = try #require(confirmation(of: error))
        #expect(asked.kind == .discardLines)
        #expect(asked.details == .files(["numbered.txt"]))

        fixture.app.preferences.confirmDiscardChanges = false
        try await fixture.changes.discardLines(.hunk(containing: try fixture.lineIndex(.add, "line two")))
        await fixture.settle()
        #expect(fixture.read("numbered.txt") == numberedLines(20, replacing: [15: "line fifteen"]))
    }

    @Test("refuses to discard lines when the file changed since its diff was shown")
    func discardLinesStale() async throws {
        let fixture = try await makeLinesFixture()
        let addTwo = try fixture.lineIndex(.add, "line two")
        // Changed on disk, not refreshed yet.
        let changed = numberedLines(20, replacing: [1: "line one", 2: "line two", 15: "line fifteen"])
        try fixture.write("numbered.txt", changed)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.line(addTwo), confirmed: [.discardLines])
        }
        #expect(preconditionText(error) != nil)
        #expect(fixture.read("numbered.txt") == changed)
        await fixture.settle()
    }

    @Test("refuses lines whose diff changed while the user was asked, and discards them when it didn't")
    func discardLinesAfterRefresh() async throws {
        let fixture = try await makeLinesFixture()
        let generation = fixture.changes.diffGeneration
        let addFifteen = try fixture.lineIndex(.add, "line fifteen")
        let asked = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.line(addFifteen), inDiff: generation)
        }
        #expect(confirmationKind(of: asked) == .discardLines)

        // Saved in an editor while the alert shows, and refreshed: a line
        // changed above moves the indexes.
        let changed = numberedLines(20, replacing: [1: "line one", 2: "line two", 15: "line fifteen"])
        try fixture.write("numbered.txt", changed)
        await fixture.refresh()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.line(addFifteen), inDiff: generation, confirmed: [.discardLines])
        }
        #expect(preconditionText(error) != nil)
        #expect(fixture.read("numbered.txt") == changed)

        // A refresh that finds the file unchanged doesn't count.
        let current = fixture.changes.diffGeneration
        let currentFifteen = try fixture.lineIndex(.add, "line fifteen")
        await fixture.refresh()
        try await fixture.changes.discardLines(.block(containing: currentFifteen), inDiff: current, confirmed: [.discardLines])
        await fixture.settle()
        #expect(fixture.read("numbered.txt") == numberedLines(20, replacing: [1: "line one", 2: "line two"]))
    }

    @Test("discards lines of a new file")
    func discardLinesOfNewFile() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("new.txt", "one\ntwo\nthree\n")
        await fixture.refresh()
        try await fixture.select("new.txt")

        try await fixture.changes.discardLines(.line(try fixture.lineIndex(.add, "two")), confirmed: [.discardLines])
        await fixture.settle()
        #expect(fixture.read("new.txt") == "one\nthree\n")
    }

    @Test("refuses lines of a file other than the one shown")
    func discardLinesOfAnotherFile() async throws {
        let fixture = try await makeLinesFixture()
        try fixture.write("other.txt", "other\n")
        await fixture.refresh()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.fromInitialSelection(.all), in: try fixture.file("other.txt"), confirmed: [.discardLines])
        }
        #expect(preconditionText(error) != nil)
        #expect(fixture.read("other.txt") == "other\n")
        await fixture.settle()
    }
}

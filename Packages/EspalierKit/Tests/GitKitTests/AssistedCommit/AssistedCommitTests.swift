// Ported from desktop's assisted commit draft (desktop#22976):
// app/test/unit/git/assisted-commit-test.ts, assisted-commit-hooks-test.ts,
// and assisted-commit-cleanup-test.ts, where they check behavior.

import Darwin
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

// MARK: Helpers

private func write(_ repository: Repository, _ path: String, _ contents: String) throws {
    let directory = POSIXPath.dirname(POSIXPath.join(repository.path, path))
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try writeFileExactly(path, contents, in: repository.path)
}

private func writeBytes(_ repository: Repository, _ path: String, _ bytes: [UInt8]) throws {
    try Data(bytes).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

private func read(_ repository: Repository, _ path: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, path), encoding: .utf8)
}

/// Git's output, or a failure with its error.
@discardableResult
private func run(_ repository: Repository, _ args: [String]) async throws -> String {
    let result = try await Dugite.exec(args, repository.path)
    guard result.exitCode == 0 else {
        throw TestSupportError("git \(args.joined(separator: " ")) failed: \(String(decoding: result.stderr, as: UTF8.self))")
    }
    return String(decoding: result.stdout, as: UTF8.self)
}

private func commitEverything(_ repository: Repository, _ message: String) async throws {
    try await run(repository, ["add", "-A"])
    try await run(repository, ["commit", "-m", message])
}

private func tip(_ repository: Repository, _ revision: String = "HEAD") async throws -> String {
    try await run(repository, ["rev-parse", revision]).trimmingCharacters(in: .newlines)
}

private func subjects(_ repository: Repository) async throws -> [String] {
    try await run(repository, ["log", "--format=%s"]).split(separator: "\n").map(String.init)
}

private func contents(_ repository: Repository, _ revision: String, _ path: String) async throws -> String {
    try await run(repository, ["show", "\(revision):\(path)"])
}

private func indexFile(_ repository: Repository) throws -> (bytes: Data, modified: timespec) {
    let path = POSIXPath.join(repository.path, ".git/index")
    var info = stat()
    guard stat(path, &info) == 0 else {
        throw TestSupportError("No index")
    }
    return (try Data(contentsOf: URL(filePath: path)), info.st_mtimespec)
}

/// The working directory's files, all of each selected.
private func everything(_ repository: Repository) async throws -> [WorkingDirectoryFileChange] {
    try await getStatusOrThrow(repository).workingDirectory.files.map { $0.withIncludeAll(true) }
}

private func capture(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    allowEmpty: Bool = false,
    options: AssistedCommitOptions = AssistedCommitOptions()
) async throws -> AssistedCommitSnapshot {
    try await AssistedCommitSnapshot.capture(
        repository,
        AssistedCommitRequest(files: files, allowEmpty: allowEmpty),
        options: options
    )
}

private func plan(_ snapshot: AssistedCommitSnapshot, _ commits: [(title: String, ids: [String])]) -> AssistedCommitPlan {
    AssistedCommitPlan(
        snapshotID: snapshot.id,
        commits: commits.map { AssistedCommitPlanCommit(title: $0.title, description: nil, changeIDs: $0.ids) }
    )
}

/// The IDs of the units of `path`, in order.
private func ids(_ snapshot: AssistedCommitSnapshot, _ path: String) -> [String] {
    snapshot.analysis.changes.filter { JSCompat.strictEquals($0.path, path) }.map(\.id)
}

/// Twenty numbered lines.
private let numberedLines = (1...20).map { "line \($0)" }

private func text(_ lines: [String]) -> String {
    lines.joined(separator: "\n") + "\n"
}

/// A repository whose a.txt has twenty lines and whose b.txt has one, and
/// with changes to lines 2 and 18 of a.txt (two hunks) and to b.txt.
private func repositoryWithTwoFiles() async throws -> Repository {
    let repository = try setupEmptyRepository()
    try write(repository, "a.txt", text(numberedLines))
    try write(repository, "b.txt", "b\n")
    try await commitEverything(repository, "Initial")
    try write(repository, "a.txt", text(changedLines))
    try write(repository, "b.txt", "b changed\n")
    return repository
}

private var changedLines: [String] {
    var lines = numberedLines
    lines[1] = "line 2 changed"
    lines[17] = "line 18 changed"
    return lines
}

/// A plan of two commits for `repositoryWithTwoFiles`: the first hunk of
/// a.txt with b.txt, then the second hunk.
private func twoCommitPlan(_ snapshot: AssistedCommitSnapshot) -> AssistedCommitPlan {
    let a = ids(snapshot, "a.txt")
    return plan(snapshot, [("Change the start", [a[0]] + ids(snapshot, "b.txt")), ("Change the end", [a[1]])])
}

private func writeAssistedHook(_ repository: Repository, _ name: String, _ script: String) throws {
    let hooks = POSIXPath.join(repository.path, ".git/hooks")
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let path = POSIXPath.join(hooks, name)
    try Data(script.utf8).write(to: URL(filePath: path))
    guard chmod(path, 0o755) == 0 else {
        throw TestSupportError("chmod failed")
    }
}

// MARK: Tests

@Suite("assisted commits", .hangGuard(minutes: 5))
struct AssistedCommitTests {
    @Test("splits the selection into the planned commits, each hunk once")
    func splitsSelection() async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)

        let snapshot = try await capture(repository, try await everything(repository))
        #expect(ids(snapshot, "a.txt").count == 2)
        #expect(ids(snapshot, "b.txt").count == 1)
        #expect(snapshot.analysis.changes.allSatisfy { $0.kind == .textHunk })

        let validated = try await snapshot.validate(twoCommitPlan(snapshot))
        let transaction = try await snapshot.execute(validated)
        try await transaction.accept()

        #expect(transaction.commits.count == 2)
        #expect(try await subjects(repository) == ["Change the end", "Change the start", "Initial"])
        #expect(try await tip(repository, "HEAD~2") == original)
        var startOnly = numberedLines
        startOnly[1] = "line 2 changed"
        #expect(try await contents(repository, "HEAD~1", "a.txt") == text(startOnly))
        #expect(try await contents(repository, "HEAD~1", "b.txt") == "b changed\n")
        #expect(try await contents(repository, "HEAD", "a.txt") == text(changedLines))
        // The index is the last commit's tree, and the files are as they were.
        #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
        #expect(try read(repository, "a.txt") == text(changedLines))
    }

    @Test("commits hunks in any order")
    func hunksInAnyOrder() async throws {
        let repository = try await repositoryWithTwoFiles()
        let snapshot = try await capture(repository, try await everything(repository))
        let a = ids(snapshot, "a.txt")
        let validated = try await snapshot.validate(plan(snapshot, [("End", [a[1]]), ("Start", [a[0]] + ids(snapshot, "b.txt"))]))
        _ = try await snapshot.execute(validated)

        var endOnly = numberedLines
        endOnly[17] = "line 18 changed"
        #expect(try await contents(repository, "HEAD~1", "a.txt") == text(endOnly))
        #expect(try await contents(repository, "HEAD", "a.txt") == text(changedLines))
    }

    @Test("leaves unselected lines and files in the working tree")
    func leavesUnselectedChanges() async throws {
        let repository = try await repositoryWithTwoFiles()
        try write(repository, "c.txt", "untracked\n")
        let files = try await everything(repository)
        let a = try #require(files.first { $0.path == "a.txt" })
        guard case .text(let diff) = try await getWorkingDirectoryDiff(repository, a) else {
            throw TestSupportError("Expected a text diff")
        }
        let firstHunk = diff.hunks[0]
        let selection = DiffSelection.fromInitialSelection(.none)
            .withRangeSelection(from: firstHunk.unifiedDiffStart, length: firstHunk.unifiedDiffEnd - firstHunk.unifiedDiffStart + 1, selected: true)

        let snapshot = try await capture(repository, [a.withSelection(selection)] + files.filter { $0.path == "b.txt" })
        #expect(ids(snapshot, "a.txt").count == 1)
        let validated = try await snapshot.validate(try await snapshot.singleCommitPlan(reason: .uncertainBoundaries, title: "Part"))
        _ = try await snapshot.execute(validated)

        var startOnly = numberedLines
        startOnly[1] = "line 2 changed"
        #expect(try await contents(repository, "HEAD", "a.txt") == text(startOnly))
        #expect(try read(repository, "a.txt") == text(changedLines))
        #expect(try read(repository, "c.txt") == "untracked\n")
        // Nothing is staged, and the rest is still a change.
        #expect(try await run(repository, ["diff", "--cached", "--name-only"]).isEmpty)
        #expect(try await run(repository, ["diff", "--name-only"]) == "a.txt\n")
        #expect(try await run(repository, ["ls-files", "--others", "--exclude-standard"]) == "c.txt\n")
    }

    typealias PlanMaker = @Sendable (_ snapshotID: String, _ ids: [String]) -> AssistedCommitPlan

    static let invalidPlans: [NamedCase<PlanMaker>] = [
        NamedCase("a change that isn't selected", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [AssistedCommitPlanCommit(title: "All", description: nil, changeIDs: ids + ["0123456789ab"])])
        }),
        NamedCase("a change in two commits", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [
                AssistedCommitPlanCommit(title: "One", description: nil, changeIDs: ids),
                AssistedCommitPlanCommit(title: "Two", description: nil, changeIDs: [ids[0]]),
            ])
        }),
        NamedCase("a change left out", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [AssistedCommitPlanCommit(title: "One", description: nil, changeIDs: [ids[0]])])
        }),
        NamedCase("an empty commit", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [
                AssistedCommitPlanCommit(title: "One", description: nil, changeIDs: ids),
                AssistedCommitPlanCommit(title: "Two", description: nil, changeIDs: []),
            ])
        }),
        NamedCase("a blank title", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [AssistedCommitPlanCommit(title: " \t", description: nil, changeIDs: ids)])
        }),
        NamedCase("a title of two lines", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [AssistedCommitPlanCommit(title: "One\nTwo", description: nil, changeIDs: ids)])
        }),
        NamedCase("a description with NUL", { snapshotID, ids in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [AssistedCommitPlanCommit(title: "One", description: "a\u{0}b", changeIDs: ids)])
        }),
        NamedCase("no commits", { snapshotID, _ in
            AssistedCommitPlan(snapshotID: snapshotID, commits: [])
        }),
        NamedCase("another snapshot's plan", { _, ids in
            AssistedCommitPlan(snapshotID: "another", commits: [AssistedCommitPlanCommit(title: "All", description: nil, changeIDs: ids)])
        }),
    ]

    @Test("rejects plans of the wrong shape, and still validates a good one", arguments: AssistedCommitTests.invalidPlans)
    func rejectsInvalidPlans(_ testCase: NamedCase<PlanMaker>) async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)
        let snapshot = try await capture(repository, try await everything(repository))
        let all = snapshot.analysis.changes.map(\.id)

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.validate(testCase.value(snapshot.id, all))
        }
        #expect(error?.code == .invalidPlan)
        #expect(try await tip(repository) == original)

        // An invalid plan is never a reason to fall back, but the snapshot
        // still takes a good plan.
        _ = try await snapshot.validate(twoCommitPlan(snapshot))
        try await snapshot.dispose()
    }

    @Test("fails a split that adds a file's child before deleting the file, and commits it as one")
    func unsafeSplit() async throws {
        let repository = try setupEmptyRepository()
        try write(repository, "foo", "a file\n")
        try await commitEverything(repository, "Initial")
        _ = unlink(POSIXPath.join(repository.path, "foo"))
        try write(repository, "foo/bar", "a file in a folder\n")
        let files = [
            WorkingDirectoryFileChange(path: "foo", status: .deleted(), selection: .fromInitialSelection(.all)),
            WorkingDirectoryFileChange(path: "foo/bar", status: .untracked(), selection: .fromInitialSelection(.all)),
        ]

        let snapshot = try await capture(repository, files)
        let deletion = ids(snapshot, "foo")
        let addition = ids(snapshot, "foo/bar")
        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.validate(plan(snapshot, [("Add bar", addition), ("Delete foo", deletion)]))
        }
        #expect(error?.code == .unsafePlan)

        let single = try await snapshot.singleCommitPlan(reason: .unsafeSplit, title: "Replace foo with a folder")
        _ = try await snapshot.execute(try await snapshot.validate(single))
        #expect(try await run(repository, ["ls-tree", "-r", "--name-only", "HEAD"]) == "foo/bar\n")
    }

    @Test("commits a deletion before the file's child as two commits")
    func deletionThenChild() async throws {
        let repository = try setupEmptyRepository()
        try write(repository, "foo", "a file\n")
        try await commitEverything(repository, "Initial")
        _ = unlink(POSIXPath.join(repository.path, "foo"))
        try write(repository, "foo/bar", "a file in a folder\n")
        let files = [
            WorkingDirectoryFileChange(path: "foo", status: .deleted(), selection: .fromInitialSelection(.all)),
            WorkingDirectoryFileChange(path: "foo/bar", status: .untracked(), selection: .fromInitialSelection(.all)),
        ]

        let snapshot = try await capture(repository, files)
        let validated = try await snapshot.validate(plan(snapshot, [("Delete foo", ids(snapshot, "foo")), ("Add bar", ids(snapshot, "foo/bar"))]))
        _ = try await snapshot.execute(validated)
        #expect(try await run(repository, ["ls-tree", "-r", "--name-only", "HEAD~1"]).isEmpty)
        #expect(try await run(repository, ["ls-tree", "-r", "--name-only", "HEAD"]) == "foo/bar\n")
    }

    @Test("keeps renames, binary files, and mode changes whole")
    func atomicChanges() async throws {
        let repository = try setupEmptyRepository()
        try write(repository, "old.txt", "renamed\n")
        try writeBytes(repository, "image.bin", [0, 1, 2, 3, 0, 255])
        try write(repository, "script.sh", "echo hi\n")
        try await commitEverything(repository, "Initial")
        try await run(repository, ["mv", "old.txt", "new.txt"])
        try writeBytes(repository, "image.bin", [0, 1, 2, 4, 0, 254])
        _ = chmod(POSIXPath.join(repository.path, "script.sh"), 0o755)

        let snapshot = try await capture(repository, try await everything(repository))
        #expect(snapshot.analysis.changes.count == 3)
        #expect(snapshot.analysis.changes.allSatisfy { $0.kind == .atomic })
        #expect(snapshot.analysis.changes.first { $0.path == "new.txt" }?.oldPath == "old.txt")

        let validated = try await snapshot.validate(plan(snapshot, [
            ("Rename", ids(snapshot, "new.txt")),
            ("Image", ids(snapshot, "image.bin")),
            ("Executable", ids(snapshot, "script.sh")),
        ]))
        _ = try await snapshot.execute(validated)
        #expect(try await run(repository, ["ls-tree", "-r", "--name-only", "HEAD~2"]) == "image.bin\nnew.txt\nscript.sh\n")
        #expect(try await run(repository, ["ls-tree", "HEAD", "script.sh"]).hasPrefix("100755 "))
        #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
    }

    @Test("refuses part of a binary file")
    func partialBinary() async throws {
        let repository = try setupEmptyRepository()
        try writeBytes(repository, "image.bin", [0, 1, 2])
        try await commitEverything(repository, "Initial")
        try writeBytes(repository, "image.bin", [0, 1, 3])
        let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(1, selected: true)
        let file = WorkingDirectoryFileChange(path: "image.bin", status: .modified(), selection: selection)

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await capture(repository, [file])
        }
        #expect(error?.code == .unsafeSelection)
    }

    @Test("refuses part of a change to a last line without its newline")
    func partialMissingNewline() async throws {
        let repository = try setupEmptyRepository()
        try write(repository, "a.txt", "a\nb")
        try await commitEverything(repository, "Initial")
        try write(repository, "a.txt", "a\nb\nc\n")
        // Only "+c": keeping "b" without its newline would join it to "c".
        let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(4, selected: true)
        let file = WorkingDirectoryFileChange(path: "a.txt", status: .modified(), selection: selection)

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await capture(repository, [file])
        }
        #expect(error?.code == .unsafeSelection)
    }

    @Test("refuses a selection while a merge is in progress")
    func mergeInProgress() async throws {
        let repository = try await setupConflictedRepo()
        let file = WorkingDirectoryFileChange(path: "foo", status: .modified(), selection: .fromInitialSelection(.all))
        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await capture(repository, [file])
        }
        #expect(error?.code == .unsafeSelection)
    }

    @Test("fails when a selected file changes", arguments: [
        NamedCase("before validating", true),
        NamedCase("before executing", false),
    ])
    func selectionChanged(_ testCase: NamedCase<Bool>) async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)
        let snapshot = try await capture(repository, try await everything(repository))

        if testCase.value {
            try write(repository, "b.txt", "b changed again\n")
            let error = await #expect(throws: AssistedCommitError.self) {
                _ = try await snapshot.validate(twoCommitPlan(snapshot))
            }
            #expect(error?.code == .selectionChanged)
            try await snapshot.dispose()
        } else {
            let validated = try await snapshot.validate(twoCommitPlan(snapshot))
            try write(repository, "b.txt", "b changed again\n")
            let error = await #expect(throws: AssistedCommitError.self) {
                _ = try await snapshot.execute(validated)
            }
            #expect(error?.code == .selectionChanged)
            #expect(error?.recovery?.needsAttention == false)
        }
        #expect(try await tip(repository) == original)
        #expect(try read(repository, "b.txt") == "b changed again\n")
    }

    @Test("leaves the branch alone when something else moves it before the commits")
    func headMoved() async throws {
        let repository = try await repositoryWithTwoFiles()
        let snapshot = try await capture(repository, try await everything(repository))
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))
        try await run(repository, ["commit", "--allow-empty", "-m", "Elsewhere"])
        let moved = try await tip(repository)

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated)
        }
        #expect(error?.code == .repositoryChanged)
        #expect(error?.recovery?.needsAttention == false)
        #expect(try await tip(repository) == moved)
    }

    @Test("fails without overwriting an index that something else changed")
    func indexChanged() async throws {
        let repository = try await repositoryWithTwoFiles()
        try write(repository, "c.txt", "staged elsewhere\n")
        let original = try await tip(repository)
        let snapshot = try await capture(repository, try await everything(repository).filter { $0.path != "c.txt" })
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))
        try await run(repository, ["add", "c.txt"])

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated)
        }
        #expect(error?.code == .indexChanged)
        #expect(try await tip(repository) == original)
        #expect(try await run(repository, ["diff", "--cached", "--name-only"]) == "c.txt\n")
    }

    typealias StageMatcher = @Sendable (AssistedCommitProgress) -> Bool

    static let cancellationStages: [NamedCase<StageMatcher>] = [
        NamedCase("while capturing", { $0 == .capturing }),
        NamedCase("while validating", { $0 == .validating }),
        NamedCase("before the first commit", { progress in
            if case .committing(0, _, _) = progress { true } else { false }
        }),
        NamedCase("after the first commit", { progress in
            if case .committed(0, _, _) = progress { true } else { false }
        }),
        NamedCase("after the last commit", { progress in
            if case .committed(1, _, _) = progress { true } else { false }
        }),
    ]

    @Test("stops and recovers when cancelled", arguments: AssistedCommitTests.cancellationStages)
    func cancellation(_ testCase: NamedCase<StageMatcher>) async throws {
        let repository = try await repositoryWithTwoFiles()
        let files = try await everything(repository)
        let original = try await tip(repository)
        let index = try indexFile(repository)
        let cancellation = AssistedCommitCancellation()
        let isStage = testCase.value
        let options = AssistedCommitOptions(cancellation: cancellation, onProgress: { progress in
            if isStage(progress) {
                cancellation.cancel()
            }
        })

        let error = await #expect(throws: AssistedCommitError.self) {
            let snapshot = try await capture(repository, files, options: options)
            do {
                let validated = try await snapshot.validate(twoCommitPlan(snapshot), options: options)
                _ = try await snapshot.execute(validated, options: options)
            } catch {
                try? await snapshot.dispose()
                throw error
            }
        }
        #expect(error?.code == .cancelled)
        #expect(error?.recovery?.needsAttention != true)
        #expect(try await tip(repository) == original)
        let restored = try indexFile(repository)
        #expect(restored.bytes == index.bytes)
        #expect(restored.modified.tv_sec == index.modified.tv_sec && restored.modified.tv_nsec == index.modified.tv_nsec)
        #expect(try read(repository, "a.txt") == text(changedLines))
    }

    @Test("rolls a finished run back until it's accepted")
    func rollbackBeforeAcceptance() async throws {
        let repository = try await repositoryWithTwoFiles()
        let files = try await everything(repository)
        let original = try await tip(repository)
        let index = try indexFile(repository)
        let snapshot = try await capture(repository, files)
        let transaction = try await snapshot.execute(try await snapshot.validate(twoCommitPlan(snapshot)))
        #expect(try await tip(repository) != original)

        let recovery = try await transaction.rollback()
        #expect(recovery.history == .restored)
        #expect(recovery.index == .restored)
        #expect(try await tip(repository) == original)
        let restored = try indexFile(repository)
        #expect(restored.bytes == index.bytes)
        #expect(restored.modified.tv_sec == index.modified.tv_sec && restored.modified.tv_nsec == index.modified.tv_nsec)
        #expect(try read(repository, "a.txt") == text(changedLines))

        let error = await #expect(throws: AssistedCommitError.self) {
            try await transaction.accept()
        }
        #expect(error?.code == .disposed)
    }

    @Test("can't roll back accepted commits")
    func acceptedIsFinal() async throws {
        let repository = try await repositoryWithTwoFiles()
        let snapshot = try await capture(repository, try await everything(repository))
        let transaction = try await snapshot.execute(try await snapshot.validate(twoCommitPlan(snapshot)))
        try await transaction.accept()
        let accepted = try await tip(repository)

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await transaction.rollback()
        }
        #expect(error?.code == .disposed)
        #expect(try await tip(repository) == accepted)
    }

    @Test("rolls back the commits it made when a hook fails on a later one")
    func hookFailsLater() async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)
        let counter = POSIXPath.join(try createTempDirectory(), "count")
        try writeAssistedHook(repository, "pre-commit", """
            #!/bin/sh
            count=$(cat '\(counter)' 2>/dev/null || echo 0)
            count=$((count + 1))
            echo "$count" > '\(counter)'
            [ "$count" -lt 2 ]

            """)
        let snapshot = try await capture(repository, try await everything(repository))
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated)
        }
        #expect(error?.code == .commitFailed)
        #expect(error?.recovery?.createdCommits.count == 1)
        #expect(error?.recovery?.history == .restored)
        #expect(try await tip(repository) == original)
        #expect(try read(repository, "a.txt") == text(changedLines))
    }

    @Test("fails a commit a hook staged other changes in, keeping the hook's edits")
    func hookStagesChanges() async throws {
        let repository = try await repositoryWithTwoFiles()
        try write(repository, "other.txt", "other\n")
        let original = try await tip(repository)
        try writeAssistedHook(repository, "pre-commit", """
            #!/bin/sh
            echo hook >> other.txt
            git add other.txt

            """)
        let snapshot = try await capture(repository, try await everything(repository).filter { $0.path != "other.txt" })
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated)
        }
        #expect(error?.code == .commitFailed)
        #expect(try await tip(repository) == original)
        #expect(try read(repository, "other.txt") == "other\nhook\n")
    }

    @Test("fails when a hook changes a selected file")
    func hookChangesSelectedFile() async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)
        try writeAssistedHook(repository, "pre-commit", """
            #!/bin/sh
            echo formatted >> b.txt

            """)
        let snapshot = try await capture(repository, try await everything(repository))
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated)
        }
        #expect(error?.code == .selectionChanged)
        #expect(try await tip(repository) == original)
        #expect(try read(repository, "b.txt") == "b changed\nformatted\n")
    }

    @Test("keeps the message a commit-msg hook writes")
    func commitMessageHook() async throws {
        let repository = try await repositoryWithTwoFiles()
        try writeAssistedHook(repository, "commit-msg", """
            #!/bin/sh
            echo "Rewritten by the hook" > "$1"

            """)
        let snapshot = try await capture(repository, try await everything(repository))
        _ = try await snapshot.execute(try await snapshot.validate(twoCommitPlan(snapshot)))
        #expect(try await subjects(repository) == ["Rewritten by the hook", "Rewritten by the hook", "Initial"])
    }

    @Test("leaves a branch something else moved during the run, then retries the rollback")
    func interferenceAndRetry() async throws {
        let repository = try await repositoryWithTwoFiles()
        let original = try await tip(repository)
        let path = repository.path
        let moved = AssistedCommitCancellation()
        let options = AssistedCommitOptions(onProgress: { progress in
            guard case .committing(1, _, _) = progress, !moved.isCancelled else {
                return
            }
            moved.cancel()
            // Another commit on top of the run's first, as another program
            // would make it (the run holds the index's lock).
            let repository = Repository(path: path)
            let tree = (try? await tip(repository, "HEAD^{tree}")) ?? ""
            let parent = (try? await tip(repository)) ?? ""
            let other = (try? await run(repository, ["commit-tree", tree, "-p", parent, "-m", "Elsewhere"]))?
                .trimmingCharacters(in: .newlines) ?? ""
            _ = try? await run(repository, ["update-ref", "refs/heads/master", other])
        })
        let snapshot = try await capture(repository, try await everything(repository))
        let validated = try await snapshot.validate(twoCommitPlan(snapshot))

        let error = await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.execute(validated, options: options)
        }
        #expect(error?.code == .recoveryFailed)
        let recovery = try #require(error?.recovery)
        #expect(recovery.history == .interfered)
        #expect(try await subjects(repository).first == "Elsewhere")

        // Once the branch is back on the run's commit, the rollback works.
        try await run(repository, ["update-ref", "refs/heads/master", recovery.createdCommits[0]])
        let retried = try await #require(recovery.retry).rollback()
        #expect(retried.history == .restored)
        #expect(try await tip(repository) == original)
    }

    @Test("commits on an unborn branch, and leaves it unborn when cancelled", arguments: [false, true])
    func unbornBranch(_ cancels: Bool) async throws {
        let repository = try setupEmptyRepository()
        try write(repository, "a.txt", "a\n")
        try write(repository, "b.txt", "b\n")
        let cancellation = AssistedCommitCancellation()
        let options = AssistedCommitOptions(cancellation: cancellation, onProgress: { progress in
            if cancels, case .committed(1, _, _) = progress {
                cancellation.cancel()
            }
        })
        let snapshot = try await capture(repository, try await everything(repository), options: options)
        let validated = try await snapshot.validate(plan(snapshot, [("Add a", ids(snapshot, "a.txt")), ("Add b", ids(snapshot, "b.txt"))]), options: options)

        if cancels {
            let error = await #expect(throws: AssistedCommitError.self) {
                _ = try await snapshot.execute(validated, options: options)
            }
            #expect(error?.code == .cancelled)
            let result = try await Dugite.exec(["rev-parse", "--verify", "--quiet", "HEAD"], repository.path)
            #expect(result.exitCode == 1)
        } else {
            _ = try await snapshot.execute(validated, options: options)
            #expect(try await subjects(repository) == ["Add b", "Add a"])
            #expect(try await run(repository, ["rev-list", "--max-parents=0", "HEAD"]).trimmingCharacters(in: .newlines) == (try await tip(repository, "HEAD~1")))
        }
    }

    @Test("commits on a detached HEAD")
    func detachedHead() async throws {
        let repository = try await repositoryWithTwoFiles()
        try await run(repository, ["checkout", "--detach"])
        let original = try await tip(repository)
        let snapshot = try await capture(repository, try await everything(repository))
        let transaction = try await snapshot.execute(try await snapshot.validate(twoCommitPlan(snapshot)))

        #expect(transaction.head.ref == nil)
        #expect(try await tip(repository, "HEAD~2") == original)
        #expect(try await tip(repository, "master") == original)
        let symbolic = try await Dugite.exec(["symbolic-ref", "--quiet", "HEAD"], repository.path)
        #expect(symbolic.exitCode == 1)
    }

    @Test("makes an empty commit with nothing selected")
    func emptyCommit() async throws {
        let repository = try await repositoryWithTwoFiles()
        let snapshot = try await capture(repository, [], allowEmpty: true)
        #expect(snapshot.analysis.changes.isEmpty)
        await #expect(throws: AssistedCommitError.self) {
            _ = try await snapshot.singleCommitPlan(reason: .uncertainBoundaries, title: "Not empty")
        }
        let single = try await snapshot.singleCommitPlan(reason: .emptySelection, title: "Empty commit")
        _ = try await snapshot.execute(try await snapshot.validate(single))

        #expect(try await subjects(repository).first == "Empty commit")
        #expect(try await tip(repository, "HEAD^{tree}") == (try await tip(repository, "HEAD~1^{tree}")))
        #expect(try read(repository, "a.txt") == text(changedLines))
    }

    @Test("signs off and adds trailers to every commit")
    func signOffAndTrailers() async throws {
        let repository = try await repositoryWithTwoFiles()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(
            files: try await everything(repository),
            trailers: [Trailer(token: "Co-Authored-By", value: "Jane Doe <jane@example.com>")],
            signOff: true
        ))
        _ = try await snapshot.execute(try await snapshot.validate(twoCommitPlan(snapshot)))
        for revision in ["HEAD", "HEAD~1"] {
            let message = try await run(repository, ["log", "-1", "--format=%B", revision])
            #expect(message.contains("Co-Authored-By: Jane Doe <jane@example.com>"))
            #expect(message.contains("Signed-off-by: \(TestEnvironment.authorName) <\(TestEnvironment.authorEmail)>"))
        }
    }

    @Test("commits only the named file when its name reads as a pattern", arguments: PatternPath.representative)
    func patternNames(_ pattern: PatternPath) async throws {
        let repository = try setupEmptyRepository()
        try writeFileExactly(pattern.name, "name\n", in: repository.path)
        try writeFileExactly(pattern.decoy, "decoy\n", in: repository.path)
        try await commitEverything(repository, "Initial")
        try writeFileExactly(pattern.name, "name changed\n", in: repository.path)
        try writeFileExactly(pattern.decoy, "decoy changed\n", in: repository.path)
        let file = WorkingDirectoryFileChange(path: pattern.name, status: .modified(), selection: .fromInitialSelection(.all))

        let snapshot = try await capture(repository, [file])
        _ = try await snapshot.execute(try await snapshot.validate(try await snapshot.singleCommitPlan(reason: .uncertainBoundaries, title: "Name")))
        let changed = try await run(repository, ["diff-tree", "--no-commit-id", "-r", "-z", "--name-only", "HEAD"])
        #expect(changed == "\(pattern.name)\0")
        #expect(try await run(repository, ["diff", "--name-only", "-z"]) == "\(pattern.decoy)\0")
    }

    @Test("commits in a linked worktree, on its own branch")
    func linkedWorktree() async throws {
        let main = try await repositoryWithTwoFiles()
        let original = try await tip(main)
        let path = POSIXPath.join(try createTempDirectory(), "linked")
        try await run(main, ["worktree", "add", "-b", "feature", path])
        let linked = Repository(path: path)
        try write(linked, "b.txt", "b in the worktree\n")

        let snapshot = try await capture(linked, try await everything(linked))
        _ = try await snapshot.execute(try await snapshot.validate(try await snapshot.singleCommitPlan(reason: .uncertainBoundaries, title: "Worktree")))
        #expect(try await subjects(linked).first == "Worktree")
        #expect(try await tip(main, "master") == original)
        #expect(try await getStatusOrThrow(linked).workingDirectory.files.isEmpty)
    }
}

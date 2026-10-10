// GitKit passes the user's paths to git as literal pathspecs. As patterns,
// a name with `*`, `?`, or `[...]` would also name the files the pattern
// matched, and a leading `:` would be read as magic (`:!e.txt` names every
// file but e.txt): checking out, removing, staging, or unstaging one file
// would change others.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// Runs git in `repository`, reading pathspecs literally, and requires
/// success.
@discardableResult
private func run(_ args: [String], _ repository: Repository, successExitCodes: Set<Int> = [0]) async throws -> String {
    try await git(
        args,
        repository.path,
        "test",
        options: GitExecutionOptions(env: ["GIT_LITERAL_PATHSPECS": "1"], successExitCodes: successExitCodes)
    ).stdout
}

/// The paths a `-z` listing of git's names.
private func paths(_ args: [String], _ repository: Repository) async throws -> Set<String> {
    Set(JSCompat.split(try await run(args + ["-z"], repository), "\0").filter { !$0.isEmpty })
}

private func staged(_ repository: Repository) async throws -> Set<String> {
    try await paths(["diff", "--cached", "--name-only", "--no-renames"], repository)
}

private func unmerged(_ repository: Repository) async throws -> Set<String> {
    try await paths(["diff", "--name-only", "--diff-filter=U"], repository)
}

private func tracked(_ repository: Repository) async throws -> Set<String> {
    try await paths(["ls-files"], repository)
}

private func write(_ repository: Repository, _ path: String, _ contents: String) throws {
    try writeFileExactly(path, contents, in: repository.path)
}

private func read(_ repository: Repository, _ path: String) -> String? {
    readFileExactly(path, in: repository.path)
}

/// Lines `1` through `count`, each "line N", newline-terminated.
private func numbered(_ count: Int, replacing replacements: [Int: String] = [:]) -> String {
    (1...count).map { replacements[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
}

private func addedLines(_ diff: Diff) -> [String] {
    let hunks: [DiffHunk]
    switch diff {
    case .text(let text): hunks = text.hunks
    case .largeText(let text): hunks = text.hunks
    default: hunks = []
    }
    return hunks.flatMap(\.lines).filter { $0.type == .add }.map(\.content)
}

/// A repository with the name and its decoy committed, each holding its
/// name.
private func makeRepository(_ path: PatternPath) async throws -> Repository {
    let repository = try setupEmptyRepository()
    try write(repository, path.name, "name\n")
    try write(repository, path.decoy, "decoy\n")
    try await run(["add", "-A"], repository)
    try await run(["commit", "-m", "Add both"], repository)
    return repository
}

/// Both files changed on `other` and, differently, on the current branch,
/// then `other` merged: both conflict.
private func makeConflictedRepository(_ path: PatternPath) async throws -> Repository {
    let repository = try await makeRepository(path)
    try await run(["checkout", "-q", "-b", "other"], repository)
    try write(repository, path.name, "name theirs\n")
    try write(repository, path.decoy, "decoy theirs\n")
    try await run(["commit", "-qam", "Theirs"], repository)
    try await run(["checkout", "-q", "-"], repository)
    try write(repository, path.name, "name ours\n")
    try write(repository, path.decoy, "decoy ours\n")
    try await run(["commit", "-qam", "Ours"], repository)
    try await run(["merge", "other"], repository, successExitCodes: [1])
    #expect(try await unmerged(repository) == [path.name, path.decoy])
    return repository
}

/// The changed file at `path`, as git's status has it.
private func file(_ repository: Repository, _ path: String) async throws -> WorkingDirectoryFileChange {
    try #require(try await getStatusOrThrow(repository).workingDirectory.files.first { $0.path == path }, "No changed file \(path)")
}

@Suite("Literal pathspecs")
struct LiteralPathspecTests {
    @Test("a path becomes a literal pathspec; an empty one stays empty, which git refuses")
    func literalPathspecForm() {
        #expect(literalPathspec("a*.txt") == ":(literal)a*.txt")
        #expect(literalPathspecs([":!e.txt", "dir/[ab].txt"]) == [":(literal):!e.txt", ":(literal)dir/[ab].txt"])
        // `:(literal)` alone names every file.
        #expect(literalPathspec("").isEmpty)
    }

    @Test("checkoutPaths restores only the named file", arguments: PatternPath.representative)
    func checkoutPathsRestoresOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try write(repository, path.name, "name changed\n")
        try write(repository, path.decoy, "decoy changed\n")

        try await checkoutPaths(repository, [path.name])

        #expect(read(repository, path.name) == "name\n")
        #expect(read(repository, path.decoy) == "decoy changed\n")
    }

    @Test("resetPaths unstages only the named file", arguments: PatternPath.representative)
    func resetPathsUnstagesOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try write(repository, path.name, "name changed\n")
        try write(repository, path.decoy, "decoy changed\n")
        try await run(["add", "-A"], repository)

        try await resetPaths(repository, .mixed, "HEAD", [path.name])

        #expect(try await staged(repository) == [path.decoy])
        #expect(read(repository, path.name) == "name changed\n")
    }

    @Test("addConflictedFile stages only the named file", arguments: PatternPath.representative)
    func addStagesOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try write(repository, path.name, "name changed\n")
        try write(repository, path.decoy, "decoy changed\n")

        try await addConflictedFile(repository, try await file(repository, path.name))

        #expect(try await staged(repository) == [path.name])
    }

    @Test("removeConflictedFile removes only the named file", arguments: PatternPath.representative)
    func removeRemovesOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try write(repository, path.name, "name\n")
        let file = WorkingDirectoryFileChange(path: path.name, status: .modified(), selection: .fromInitialSelection(.all))

        try await removeConflictedFile(repository, file)

        #expect(read(repository, path.name) == nil)
        #expect(read(repository, path.decoy) == "decoy\n")
        #expect(try await tracked(repository) == [path.decoy])
    }

    @Test("checkoutConflictedFile takes a side of only the named file", arguments: PatternPath.representative)
    func checkoutConflictedTakesOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeConflictedRepository(path)

        try await checkoutConflictedFile(repository, try await file(repository, path.name), .theirs)

        #expect(read(repository, path.name) == "name theirs\n")
        #expect(read(repository, path.decoy)?.contains("<<<<<<<") == true)
    }

    @Test("stageManualConflictResolution resolves only the named file", arguments: PatternPath.representative, [ManualConflictResolution.ours, .theirs])
    func manualResolutionResolvesOnlyTheName(_ path: PatternPath, resolution: ManualConflictResolution) async throws {
        let repository = try await makeConflictedRepository(path)
        // The user resolved the decoy by hand, without staging it.
        try write(repository, path.decoy, "decoy by hand\n")

        try await stageManualConflictResolution(repository, try await file(repository, path.name), resolution)

        #expect(read(repository, path.name) == (resolution == .ours ? "name ours\n" : "name theirs\n"))
        #expect(read(repository, path.decoy) == "decoy by hand\n")
        #expect(try await unmerged(repository) == [path.decoy])
    }

    @Test("a manual resolution that deletes the named file deletes only it", arguments: PatternPath.representative)
    func deletingResolutionDeletesOnlyTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try await run(["checkout", "-q", "-b", "other"], repository)
        try await run(["rm", "-q", "--", path.name], repository)
        try await run(["commit", "-qm", "Delete the name"], repository)
        try await run(["checkout", "-q", "-"], repository)
        try write(repository, path.name, "name ours\n")
        try await run(["commit", "-qam", "Change the name"], repository)
        try await run(["merge", "other"], repository, successExitCodes: [1])
        #expect(try await unmerged(repository) == [path.name])

        try await stageManualConflictResolution(repository, try await file(repository, path.name), .theirs)

        #expect(read(repository, path.name) == nil)
        #expect(read(repository, path.decoy) == "decoy\n")
        #expect(try await tracked(repository) == [path.decoy])
        #expect(try await staged(repository) == [path.name])
    }

    @Test("the working directory diff is the named file's alone", arguments: PatternPath.representative)
    func workingDirectoryDiffIsTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try write(repository, path.name, "name changed\n")
        try write(repository, path.decoy, "decoy changed\n")

        let diff = try await getWorkingDirectoryDiff(repository, try await file(repository, path.name))

        #expect(addedLines(diff) == ["name changed"])
    }

    @Test("a commit's, a range's, and a merge base's diffs are the named file's alone", arguments: PatternPath.representative)
    func committedDiffsAreTheName(_ path: PatternPath) async throws {
        let repository = try await makeRepository(path)
        try await run(["checkout", "-q", "-b", "other"], repository)
        try write(repository, path.name, "name changed\n")
        try write(repository, path.decoy, "decoy changed\n")
        try await run(["commit", "-qam", "Change both"], repository)
        let sha = JSCompat.trim(try await run(["rev-parse", "HEAD"], repository))
        let file = CommittedFileChange(path: path.name, status: .modified(), commitish: sha, parentCommitish: "\(sha)^")

        #expect(addedLines(try await getCommitDiff(repository, file, sha)) == ["name changed"])
        #expect(addedLines(try await getCommitRangeDiff(repository, file, [sha])) == ["name changed"])
        let mergeBaseDiff = try await getBranchMergeBaseDiff(repository, file, "master", "other", latestCommit: sha)
        #expect(addedLines(mergeBaseDiff) == ["name changed"])
    }

    @Test("a partial commit commits only the named file's selected lines", arguments: PatternPath.representative)
    func partialCommitCommitsOnlyTheName(_ path: PatternPath) async throws {
        let repository = try setupEmptyRepository()
        try write(repository, path.name, numbered(20))
        try write(repository, path.decoy, "decoy\n")
        try await run(["add", "-A"], repository)
        try await run(["commit", "-m", "Add both"], repository)
        try write(repository, path.name, numbered(20, replacing: [2: "line two", 15: "line fifteen"]))
        try write(repository, path.decoy, "decoy changed\n")

        let changed = try await file(repository, path.name)
        guard case .text(let diff) = try await getWorkingDirectoryDiff(repository, changed) else {
            Issue.record("Expected a text diff")
            return
        }
        var selection = DiffSelection.fromInitialSelection(.all)
        for hunk in diff.hunks {
            for (offset, line) in hunk.lines.enumerated() where line.content.hasSuffix("15") || line.content == "line fifteen" {
                selection = selection.withLineSelection(hunk.unifiedDiffStart + offset, selected: false)
            }
        }
        try await createCommit(repository, "Line two", [changed.withSelection(selection)])

        #expect(try await run(["show", "HEAD:\(path.name)"], repository) == numbered(20, replacing: [2: "line two"]))
        #expect(try await paths(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], repository) == [path.name])
        #expect(read(repository, path.decoy) == "decoy changed\n")
    }

    @Test("a partly committed rename stages only its old path's removal", arguments: PatternPath.representative)
    func partlyCommittedRenameStagesOnlyTheOldPath(_ path: PatternPath) async throws {
        let repository = try setupEmptyRepository()
        try write(repository, path.name, numbered(20))
        try write(repository, path.decoy, "decoy\n")
        try await run(["add", "-A"], repository)
        try await run(["commit", "-m", "Add both"], repository)
        try await run(["mv", "--", path.name, "moved.txt"], repository)
        try write(repository, "moved.txt", numbered(20, replacing: [2: "line two", 15: "line fifteen"]))
        try write(repository, path.decoy, "decoy changed\n")

        let moved = try await file(repository, "moved.txt")
        guard case .renamed(let oldPath, _, _) = moved.status else {
            Issue.record("Expected a rename, got \(moved.status)")
            return
        }
        #expect(oldPath == path.name)
        guard case .text(let diff) = try await getWorkingDirectoryDiff(repository, moved) else {
            Issue.record("Expected a text diff")
            return
        }
        var selection = DiffSelection.fromInitialSelection(.all)
        for hunk in diff.hunks {
            for (offset, line) in hunk.lines.enumerated() where line.content.hasSuffix("15") || line.content == "line fifteen" {
                selection = selection.withLineSelection(hunk.unifiedDiffStart + offset, selected: false)
            }
        }
        try await createCommit(repository, "Move", [moved.withSelection(selection)])

        #expect(try await paths(["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "HEAD"], repository) == [path.name, "moved.txt"])
        #expect(try await run(["show", "HEAD:moved.txt"], repository) == numbered(20, replacing: [2: "line two"]))
        #expect(read(repository, path.decoy) == "decoy changed\n")
    }

    @Test("resetSubmodulePaths updates only the named submodule")
    func resetSubmodulePathsUpdatesOnlyTheName() async throws {
        let library = try setupEmptyRepository()
        try write(library, "f.txt", "one\n")
        try await run(["add", "-A"], library)
        try await run(["commit", "-m", "One"], library)
        try write(library, "f.txt", "two\n")
        try await run(["commit", "-qam", "Two"], library)

        let repository = try await makeRepository(PatternPath("r.txt", decoy: "s.txt"))
        for name in ["s*b", "sab"] {
            try await run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", "--", library.path, name], repository)
        }
        try await run(["commit", "-m", "Add the submodules"], repository)
        let recorded = JSCompat.trim(try await run(["rev-parse", "HEAD"], library))
        for name in ["s*b", "sab"] {
            try await run(["checkout", "-q", "HEAD~1"], Repository(path: POSIXPath.join(repository.path, name)))
        }

        try await resetSubmodulePaths(repository, ["s*b"])

        #expect(JSCompat.trim(try await run(["rev-parse", "HEAD"], Repository(path: POSIXPath.join(repository.path, "s*b")))) == recorded)
        #expect(JSCompat.trim(try await run(["rev-parse", "HEAD"], Repository(path: POSIXPath.join(repository.path, "sab")))) != recorded)
    }
}

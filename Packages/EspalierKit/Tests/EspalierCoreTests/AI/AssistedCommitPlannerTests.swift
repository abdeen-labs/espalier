// Ported from desktop/app/test/unit/git/assisted-commit-planning-test.ts:
// the planner's glue between the snapshot and the model, with the model
// replaced by a closure. Only a valid split that can't be committed in its
// order gets one more turn.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// The modes the planner asked in, in order.
private final class Turns: Sendable {
    private let state = Mutex<[AIAssistedCommitPlanningMode]>([])

    func record(_ mode: AIAssistedCommitPlanningMode) {
        state.withLock { $0.append(mode) }
    }

    var modes: [AIAssistedCommitPlanningMode] {
        state.withLock { $0 }
    }
}

/// A repository whose `foo` file is deleted and replaced by `foo/bar`.
private func fileReplacedByFolder() async throws -> (Repository, [WorkingDirectoryFileChange]) {
    let repository = try setupEmptyRepository()
    try await commit(["foo": "a file\n"], "Initial", in: repository)
    _ = unlink(POSIXPath.join(repository.path, "foo"))
    try FileManager.default.createDirectory(atPath: POSIXPath.join(repository.path, "foo"), withIntermediateDirectories: true)
    try Data("a file in a folder\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "foo/bar")))
    return (repository, [
        WorkingDirectoryFileChange(path: "foo", status: .deleted(), selection: .fromInitialSelection(.all)),
        WorkingDirectoryFileChange(path: "foo/bar", status: .untracked(), selection: .fromInitialSelection(.all)),
    ])
}

/// A repository with changes to two files.
private func twoChangedFiles() async throws -> (Repository, [WorkingDirectoryFileChange]) {
    let repository = try setupEmptyRepository()
    try await commit(["a.txt": "a\n", "b.txt": "b\n"], "Initial", in: repository)
    try Data("a changed\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "a.txt")))
    try Data("b changed\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "b.txt")))
    return (repository, [
        WorkingDirectoryFileChange(path: "a.txt", status: .modified(), selection: .fromInitialSelection(.all)),
        WorkingDirectoryFileChange(path: "b.txt", status: .modified(), selection: .fromInitialSelection(.all)),
    ])
}

private func plan(
    _ snapshot: AssistedCommitSnapshot,
    _ turns: Turns,
    _ answer: @escaping @Sendable (AIAssistedCommitAnalysis, AIAssistedCommitPlanningMode) throws -> AIAssistedCommitResponse
) async throws -> ValidatedAssistedCommitPlan {
    try await AssistedCommitPlanner.plan(snapshot, options: AssistedCommitOptions(), onStep: { _ in }) { analysis, mode in
        turns.record(mode)
        return try answer(analysis, mode)
    }
}

@Suite("Planning assisted commits", .hangGuard(minutes: 5))
struct AssistedCommitPlannerTests {
    @Test("validates the model's plan as it is")
    func validPlan() async throws {
        let (repository, files) = try await twoChangedFiles()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(files: files))
        let turns = Turns()
        let validated = try await plan(snapshot, turns) { analysis, _ in
            .plan(analysis.changes.map { AIAssistedCommitGroup(title: "Change \($0.path)", changeIDs: [$0.id]) })
        }
        #expect(turns.modes == [.plan])
        #expect(validated.plan.commits.map(\.title) == ["Change a.txt", "Change b.txt"])
        try await snapshot.dispose()
    }

    @Test("makes one commit of everything when the model can't tell the boundaries")
    func uncertainBoundaries() async throws {
        let (repository, files) = try await twoChangedFiles()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(files: files))
        let turns = Turns()
        let validated = try await plan(snapshot, turns) { _, _ in
            .uncertainBoundaries(title: "Change both files", description: "Together.")
        }
        #expect(turns.modes == [.plan])
        #expect(validated.plan.commits.count == 1)
        #expect(validated.plan.commits[0].title == "Change both files")
        #expect(validated.plan.commits[0].changeIDs.count == snapshot.analysis.changes.count)
        try await snapshot.dispose()
    }

    @Test("asks once more, for one fresh message, when a valid split can't be committed in its order")
    func unsafeSplitFallback() async throws {
        let (repository, files) = try await fileReplacedByFolder()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(files: files))
        let turns = Turns()
        let validated = try await plan(snapshot, turns) { analysis, mode in
            switch mode {
            case .plan:
                // The folder's file before the deletion that makes room for it.
                let ordered = analysis.changes.sorted { $0.path.count > $1.path.count }
                return .plan(ordered.map { AIAssistedCommitGroup(title: "Change \($0.path)", changeIDs: [$0.id]) })
            case .singleCommit:
                return .plan([AIAssistedCommitGroup(title: "Replace foo with a folder", changeIDs: analysis.changes.map(\.id))])
            }
        }
        #expect(turns.modes == [.plan, .singleCommit])
        #expect(validated.plan.commits.map(\.title) == ["Replace foo with a folder"])
        try await snapshot.dispose()
    }

    @Test("never falls back for a refusal or a failed request", arguments: [true, false])
    func noFallback(_ refuses: Bool) async throws {
        let (repository, files) = try await twoChangedFiles()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(files: files))
        let turns = Turns()
        await #expect(throws: (any Error).self) {
            _ = try await plan(snapshot, turns) { _, _ in
                if refuses {
                    return .unsafe(reason: "No")
                }
                throw AIAssistedCommitError(.invalidResponse, "Invalid")
            }
        }
        #expect(turns.modes == [.plan])
        try await snapshot.dispose()
    }

    @Test("sends the model the snapshot's units, and nothing else of the files")
    func analysisIsTheSnapshots() async throws {
        let (repository, files) = try await twoChangedFiles()
        let snapshot = try await AssistedCommitSnapshot.capture(repository, AssistedCommitRequest(files: files))
        let analysis = AssistedCommitPlanner.analysis(snapshot)
        #expect(analysis.snapshotID == snapshot.id)
        #expect(analysis.changes.map(\.id) == snapshot.analysis.changes.map(\.id))
        #expect(analysis.changes.map(\.diff) == snapshot.analysis.changes.map(\.diff))
        #expect(analysis.changes.allSatisfy { $0.kind == "text-hunk" })
        try await snapshot.dispose()
    }
}

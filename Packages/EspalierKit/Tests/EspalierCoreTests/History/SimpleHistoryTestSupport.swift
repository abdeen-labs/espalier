// Helpers for the tests of History's simple mode. Commits get
// fixed author and committer dates, each later than the one before, so
// their order (and git's walks, which trust that a commit is newer than its
// parents) never depends on the clock.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The tests' times.
enum SimpleTime {
    /// 2026-10-07T00:00:00Z.
    static let midnight = 1_791_331_200

    /// The time `daysAgo` days before October 7, 2026, at `hour` (UTC), in
    /// seconds.
    static func at(daysAgo: Int, hour: Int = 10) -> Int {
        midnight - daysAgo * 86_400 + hour * 3_600
    }
}

/// Runs git in `repository` with its author and committer dates at `time`
/// (seconds since 1970) and requires success.
@discardableResult
func gitAt(_ time: Int, _ args: [String], _ repository: Repository) async throws -> String {
    try await withGitEnvironment(["GIT_AUTHOR_DATE": "@\(time) +0000", "GIT_COMMITTER_DATE": "@\(time) +0000"]) {
        try await runGit(args, repository)
    }
}

/// Commits `message` at `time`, adding `files` new files named for it;
/// returns the commit.
@discardableResult
func commitAt(_ time: Int, _ message: String, files: Int = 1, in repository: Repository) async throws -> String {
    let slug = message.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    for index in 0..<files {
        let path = POSIXPath.join(repository.path, "\(String(slug))-\(index).txt")
        try Data("\(message) \(index)\n".utf8).write(to: URL(filePath: path))
    }
    try await runGit(["add", "-A"], repository)
    try await gitAt(time, ["commit", "-q", "--allow-empty", "-m", message], repository)
    return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
}

/// Merges `branch` into the current branch with `--no-ff` at `time`;
/// returns the merge.
@discardableResult
func mergeAt(_ time: Int, _ branch: String, message: String, in repository: Repository) async throws -> String {
    try await gitAt(time, ["merge", "-q", "--no-ff", "-m", message, branch], repository)
    return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
}

/// A bare remote whose `main` has `commits` (summary and time, oldest
/// first), and a clone of it on `main`.
func makeRemoteWithMain(_ commits: [(String, Int)]) async throws -> (local: Repository, remote: Repository) {
    let seed = try setupEmptyRepository("main")
    for (summary, time) in commits {
        try await commitAt(time, summary, in: seed)
    }
    let remote = try await makeBareRemote(from: seed)
    let local = try await cloneRepository(remote)
    return (local, remote)
}

/// `local` selected in an app with no History style stored, so History is
/// in the simple style (the default); the history isn't active yet.
@MainActor
func makeSimpleFixture(_ local: Repository, git: GitRuntime? = nil) async throws -> HistoryFixture {
    let harness = try AppHarness(git: git, historyStyle: nil)
    let app = await harness.loadedApp()
    let model = try await harness.addAndSelect(local, to: app)
    return HistoryFixture(harness: harness, app: app, model: model, local: local)
}

extension HistoryFixture {
    /// The simple list's lines, as text: each row's summary, marked when
    /// it isn't pushed, and an expanded merge's commits indented under it.
    var simpleLines: [String] {
        func describe(_ row: SimpleHistoryRow?) -> String {
            guard let row else {
                return "?"
            }
            return row.commit.summary + (row.isUnpushed ? " (unpushed)" : "")
        }
        return history.simpleOutline.items.map { item in
            switch item {
            case .commit(let row):
                describe(history.simpleRow(atRow: row))
            case .mergedCommit(let mergeRow, let index):
                "  " + describe(history.simpleMergedRow(mergeRow: mergeRow, index: index))
            case .mergedCommitsStatus(let mergeRow):
                "  (\(history.mergedCommits(ofRow: mergeRow).map { "\($0.state)" } ?? "?"))"
            }
        }
    }

    /// The notice above the simple list, as text: "main +2".
    var baseNotice: String? {
        history.simpleBaseStatus.map { "\($0.name) +\($0.newCommitCount)" }
    }

    /// The simple list's row whose commit has `summary`.
    func simpleRow(_ summary: String) throws -> SimpleHistoryRow {
        let row = try #require(history.commitSHAs.firstIndex { history.commit($0)?.summary == summary }, "No row \(summary)")
        return try #require(history.simpleRow(atRow: row))
    }
}

// Committing with AI against a mock OpenAI-compatible provider: the model
// sees only the frozen selection, its plan becomes the commits, the draft
// is left alone, an empty commit asks no model, invalid plans and refusals
// fail without a fallback, Stop cancels, the mode is remembered, and the
// push after the commits.

import AIKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// The analysis a planning request sent: its snapshot ID and its units'
/// IDs and paths, read from the JSON in its tagged block.
private func sentAnalysis(_ request: AIRequestRecord) -> (snapshotID: String, changes: [(id: String, path: String)]) {
    let lines = request.userPrompt.split(separator: "\n", omittingEmptySubsequences: false)
    guard let tag = lines.firstIndex(where: { $0.hasPrefix("<diff-") }), tag + 1 < lines.count,
          let object = try? JSONSerialization.jsonObject(with: Data(lines[tag + 1].utf8)) as? [String: Any],
          let snapshotID = object["snapshotId"] as? String,
          let changes = object["changes"] as? [[String: Any]]
    else {
        return ("", [])
    }
    return (snapshotID, changes.map { (($0["id"] as? String) ?? "", ($0["path"] as? String) ?? "") })
}

/// A plan with one commit per path, titled "Change <path>", in path order.
private func onePerPath(_ request: AIRequestRecord) -> AIMockReply {
    let analysis = sentAnalysis(request)
    let paths = Array(Set(analysis.changes.map(\.path))).sorted()
    let commits = paths.map { path -> [String: Any] in
        ["title": "Change \(path)", "changeIds": analysis.changes.filter { $0.path == path }.map(\.id)]
    }
    let plan: [String: Any] = ["kind": "plan", "snapshotId": analysis.snapshotID, "commits": commits]
    let data = (try? JSONSerialization.data(withJSONObject: plan)) ?? Data()
    return .content(String(decoding: data, as: UTF8.self))
}

@Suite("Committing with AI", .hangGuard(minutes: 5)) @MainActor
struct AssistedCommitModelTests {
    /// A repository with one commit and changes to `a.txt` and `b.txt`,
    /// both included, and `excluded.txt`, excluded.
    private func fixture(prepare: (Repository) async throws -> Void = { _ in }) async throws -> AIFixture {
        let fixture = try await AIFixture.make { repository in
            try await commit(["a.txt": "a\n", "b.txt": "b\n", "excluded.txt": "x\n"], "Initial commit", in: repository)
            try await prepare(repository)
        }
        try fixture.write("a.txt", "a\nmore a\n")
        try fixture.write("b.txt", "b\nmore b\n")
        try fixture.write("excluded.txt", "x\nsecret\n")
        await fixture.refresh()
        let excluded = try #require(fixture.model.changes.workingDirectory.files.first { $0.path == "excluded.txt" })
        fixture.model.changes.setIncluded([excluded.id], false)
        return fixture
    }

    private func subjects(_ fixture: AIFixture) async throws -> [String] {
        try await runGit(["log", "--format=%s"], fixture.local).split(separator: "\n").map(String.init)
    }

    @Test("makes the model's commits from the included changes only, leaving the draft alone")
    func makesPlannedCommits() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer(onePerPath)
        fixture.model.commit.draft.summary = "My own message"

        let result = try await fixture.model.commit.commitAssisted()
        await fixture.settle()

        #expect(result.commits.count == 2)
        #expect(try await subjects(fixture) == ["Change b.txt", "Change a.txt", "Initial commit"])
        #expect(fixture.model.commit.draft.summary == "My own message")
        #expect(fixture.model.commit.assisted == .idle)
        #expect(fixture.model.changes.workingDirectory.files.map(\.path) == ["excluded.txt"])

        let request = try #require(fixture.server.requests.first)
        #expect(fixture.server.requests.count == 1)
        #expect(request.userPrompt.contains("+more a"))
        #expect(!request.userPrompt.contains("secret"))
    }

    @Test("asks for consent before sending anything")
    func consentFirst() async throws {
        let fixture = try await fixture()
        try fixture.addProvider(consent: false)
        fixture.server.answer(onePerPath)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.commit.commitAssisted()
        }
        #expect(error?.reason == .ai(.consentRequired(provider: "Test AI")))
        #expect(fixture.server.requests.isEmpty)
        #expect(try await subjects(fixture) == ["Initial commit"])
    }

    @Test("makes an empty commit without asking a model")
    func emptyCommit() async throws {
        let fixture = try await fixture()
        let included = fixture.model.changes.workingDirectory.files.filter(\.isIncludedInCommit).map(\.id)
        fixture.model.changes.setIncluded(included, false)
        fixture.model.commit.options.allowEmpty = true

        try await fixture.model.commit.commitAssisted()
        await fixture.settle()

        #expect(try await subjects(fixture) == ["Empty commit", "Initial commit"])
        #expect(fixture.server.requests.isEmpty)
        #expect(!fixture.model.commit.options.allowEmpty)
    }

    @Test("fails an invalid plan without falling back, keeping nothing")
    func invalidPlan() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { request in
            // Leaves out a change.
            let analysis = sentAnalysis(request)
            let first = analysis.changes.first.map { [$0.id] } ?? []
            return .content(#"{"kind":"plan","snapshotId":"\#(analysis.snapshotID)","commits":[{"title":"Part","changeIds":["\#(first.joined())"]}]}"#)
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.commit.commitAssisted()
        }
        #expect(providerFailureMessage(error) != nil)
        #expect(fixture.server.requests.count == 1)
        #expect(try await subjects(fixture) == ["Initial commit"])
        guard case .failed = fixture.model.commit.assisted else {
            Issue.record("Expected the failure to be kept, got \(fixture.model.commit.assisted)")
            return
        }
    }

    @Test("fails when the model refuses")
    func refusal() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { request in
            .content(#"{"kind":"unsafe","snapshotId":"\#(sentAnalysis(request).snapshotID)","reason":"It looks like a secret."}"#)
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.commit.commitAssisted()
        }
        #expect(providerFailureMessage(error) == "It looks like a secret.")
        #expect(try await subjects(fixture) == ["Initial commit"])
    }

    @Test("Stop while the model plans cancels, making nothing")
    func stopWhilePlanning() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer { _ in .hang }

        let run = Task { @MainActor in
            try await fixture.model.commit.commitAssisted()
        }
        await fixture.server.waitForRequests(1)
        await until {
            if case .running(.planning) = fixture.model.commit.assisted { true } else { false }
        }
        fixture.model.commit.cancelAssistedCommit()
        let result = await run.result
        #expect((result.failure as? OperationError)?.isCancellation == true)
        #expect(fixture.model.commit.assisted == .idle)
        #expect(try await subjects(fixture) == ["Initial commit"])
    }

    @Test("remembers the mode and the push choice per repository")
    func remembersPreferences() async throws {
        let fixture = try await fixture()
        let commit = fixture.model.commit
        commit.setMode(.assisted)
        commit.setPushesAfterAssistedCommits(true)
        let defaults = fixture.harness.defaults.defaults
        #expect(defaults.string(forKey: CommitModel.commitModeKey(fixture.model.id)) == "assisted")

        defaults.set("manual", forKey: CommitModel.commitModeKey(fixture.model.id))
        defaults.set(false, forKey: CommitModel.assistedCommitPushKey(fixture.model.id))
        commit.loadAssistedCommitPreferences()
        #expect(commit.mode == .manual)
        #expect(!commit.pushesAfterAssistedCommits)
    }

    @Test("pushes the commits when asked to, keeping them when there's nowhere to push")
    func pushesAfterCommitting() async throws {
        var remotePath = ""
        let fixture = try await fixture { repository in
            let remote = try await makeEmptyBareRemote()
            remotePath = remote.path
            try await runGit(["remote", "add", "origin", remote.path], repository)
            try await runGit(["push", "-u", "origin", "main"], repository)
        }
        try fixture.addProvider()
        fixture.server.answer(onePerPath)
        fixture.model.commit.setPushesAfterAssistedCommits(true)
        await fixture.refresh()

        let result = try await fixture.model.commit.commitAssisted()
        await fixture.settle()

        #expect(result.push != nil)
        #expect(fixture.model.commit.assisted == .idle)
        let local = try await runGit(["rev-parse", "HEAD"], fixture.local)
        let remote = try await runGit(["rev-parse", "main"], Repository(path: remotePath))
        #expect(local == remote)
    }

    @Test("keeps the commits and offers Retry Push when there's no remote")
    func pushWithoutRemote() async throws {
        let fixture = try await fixture()
        try fixture.addProvider()
        fixture.server.answer(onePerPath)
        fixture.model.commit.setPushesAfterAssistedCommits(true)

        let result = try await fixture.model.commit.commitAssisted()
        await fixture.settle()

        #expect(result.commits.count == 2)
        #expect(result.push == nil)
        guard case .pushFailed = fixture.model.commit.assisted else {
            Issue.record("Expected the failed push to be kept, got \(fixture.model.commit.assisted)")
            return
        }
        #expect(try await subjects(fixture).count == 3)
        fixture.model.commit.dismissAssistedCommitFailure()
        #expect(fixture.model.commit.assisted == .idle)
    }
}

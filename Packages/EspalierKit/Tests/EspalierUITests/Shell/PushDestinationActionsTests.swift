// A repository with several remotes, through the window: Publish Branch
// (Repository ▸ Publish Branch, the sync button) asks which remote and
// publishes to the one chosen; the sync button lists the other remotes; a
// push that another remote refuses shows that remote's error with its
// Retry; and Repository Settings' Remotes pane removes, changes, and adds
// remotes on Save.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Several remotes", .offline, .hangGuard(minutes: 5)) @MainActor
struct PushDestinationActionsTests {
    /// A fixture whose repository has `origin` and a bare `mirror` at
    /// `main`'s first commit, prepared by `prepare`.
    private func makeFixture(_ prepare: @escaping (Repository) async throws -> Void = { _ in }) async throws -> (fixture: OperationsFixture, mirror: Repository) {
        let mirror = try await makeEmptyBareRemote()
        let fixture = try await makeOperationsFixture { local in
            try await runGit(["remote", "add", "mirror", mirror.path], local)
            try await runGit(["push", "-q", "mirror", "main"], local)
            try await prepare(local)
        }
        return (fixture, mirror)
    }

    /// The commit `ref` names in `repository`, or nil.
    private func tip(_ ref: String, in repository: Repository) async throws -> String? {
        let result = try await Dugite.exec(["rev-parse", "--verify", "--quiet", "--end-of-options", ref], repository.path)
        return result.exitCode == 0 ? JSCompat.trim(String(decoding: result.stdout, as: UTF8.self)) : nil
    }

    /// The decision the presenter shows, once it does.
    private func decision(_ fixture: OperationsFixture) async -> PendingDecision {
        await waitUntil { fixture.presenter.decision != nil }
        return fixture.presenter.decision!
    }

    @Test("Publish Branch asks which remote, and publishes to the one chosen")
    func publishAsks() async throws {
        let (fixture, mirror) = try await makeFixture { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }
        let head = try await fixture.sha("HEAD")

        fixture.context.actions.perform(.publishBranch)
        let asked = await decision(fixture)

        guard case .publishRemote("feature", let remotes) = asked.decision else {
            Issue.record("Unexpected decision \(asked.decision)")
            return
        }
        #expect(remotes.map(\.name) == ["origin", "mirror"])
        #expect(try await tip("refs/heads/feature", in: fixture.remote) == nil)

        fixture.presenter.respond(to: asked.id, with: .remote("mirror"))
        await fixture.settle()

        #expect(fixture.presenter.error == nil)
        #expect(fixture.presenter.decision == nil)
        #expect(try await tip("refs/heads/feature", in: mirror) == head)
        #expect(try await tip("refs/heads/feature", in: fixture.remote) == nil)
        #expect(fixture.repository.gitState.tip.branch?.upstream == "mirror/feature")
    }

    @Test("cancelling the question publishes nothing")
    func publishCancelled() async throws {
        let (fixture, mirror) = try await makeFixture { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n")
        }

        fixture.context.actions.perform(.publishBranch)
        let asked = await decision(fixture)
        fixture.presenter.respond(to: asked.id, with: nil)
        await fixture.settle()

        #expect(fixture.presenter.error == nil)
        #expect(try await tip("refs/heads/feature", in: mirror) == nil)
        #expect(try await tip("refs/heads/feature", in: fixture.remote) == nil)
        #expect(fixture.repository.gitState.tip.branch?.upstream == nil)
    }

    @Test("the sync button lists the repository's other remotes, checked where a push also goes; with one remote it lists none")
    func syncButtonDestinations() async throws {
        let (fixture, _) = try await makeFixture()
        let state = { SyncButtonState.make(fixture.repository, preferences: fixture.app.preferences) }
        #expect(state().destinations == [SyncPushDestination(name: "mirror", isOn: false)])
        #expect(state().hasMenu)

        try await fixture.repository.sync.setPushDestination("mirror", true)
        #expect(state().destinations == [SyncPushDestination(name: "mirror", isOn: true)])

        try await fixture.repository.sync.removeRemote("mirror")
        #expect(state().destinations.isEmpty)
        #expect(!state().hasMenu)
        await fixture.settle()
    }

    @Test("a push another remote refuses reaches the branch's own remote, and shows the other's error with its Retry")
    func refusedByAnotherRemote() async throws {
        let (fixture, mirror) = try await makeFixture { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        try await fixture.repository.sync.setPushDestination("mirror", true)
        let head = try await fixture.sha("HEAD")
        let seed = try await fixture.sha("HEAD~1")
        let hook = POSIXPath.join(mirror.path, "hooks", "pre-receive")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(hook), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'not now' >&2\nexit 1\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        fixture.context.actions.perform(.push)
        await fixture.settle()

        #expect(try await tip("refs/heads/main", in: fixture.remote) == head)
        #expect(try await tip("refs/heads/main", in: mirror) == seed)
        let error = try #require(fixture.presenter.error)
        #expect((error.error.retry as? PushRetry)?.request.onlyRemote == "mirror")
        // No remote but the branch's own took the push: nothing to say.
        #expect(fixture.presenter.toasts.isEmpty)

        try FileManager.default.removeItem(atPath: hook)
        // Git's own words for the refusal, in a sheet, with Retry.
        guard case .rawOutput(_, let recoveries) = error.error.presentation(defaultNumberFormat) else {
            Issue.record("The error doesn't show git's output: \(error.error.reason)")
            return
        }
        let retry = try #require(recoveries.first)
        await fixture.presenter.recover(error.id, with: retry)
        await fixture.settle()

        #expect(fixture.presenter.error == nil)
        #expect(try await tip("refs/heads/main", in: mirror) == head)
    }

    @Test("a push the other remotes take says so")
    func takenByAnotherRemote() async throws {
        let (fixture, mirror) = try await makeFixture { local in
            try await commitFile(local, "a.txt", "a\n")
        }
        try await fixture.repository.sync.setPushDestination("mirror", true)

        fixture.context.actions.perform(.push)
        await fixture.settle()

        #expect(fixture.presenter.error == nil)
        #expect(try await tip("refs/heads/main", in: mirror) == (try await fixture.sha("HEAD")))
        #expect(fixture.presenter.toasts.count == 1)
    }

    // MARK: Repository Settings

    @Test("Save removes the remotes taken off the list, changes URLs, and adds the new ones")
    func settingsSave() async throws {
        let (fixture, mirror) = try await makeFixture()
        let moved = try await makeBareRemote(from: fixture.remote)
        let archive = try await makeEmptyBareRemote()
        let model = RepositorySettingsModel(repository: fixture.repository, app: fixture.app)
        await model.load()
        #expect(model.remotes.map(\.name) == ["origin", "mirror"])
        #expect(model.remotes.map(\.url) == [fixture.remote.path, mirror.path])

        model.remotes[0].url = moved.path
        model.removeRemote(model.remotes[1].id)
        model.addRemote()
        model.remotes[1].name = "archive"
        #expect(!model.canSave)
        model.remotes[1].url = archive.path
        // One with nothing typed isn't in Save's way, and isn't added.
        model.addRemote()
        #expect(model.canSave)
        // Nothing changes until Save.
        #expect(fixture.repository.gitState.remotes.all.map(\.name) == ["mirror", "origin"])

        #expect(await model.save())

        let remotes = fixture.repository.gitState.remotes.all
        #expect(remotes == [Remote(name: "archive", url: archive.path), Remote(name: "origin", url: moved.path)])
        #expect(model.remotes.map(\.name) == ["origin", "archive"])
        #expect(model.remotes.allSatisfy { !$0.isNew })
        #expect(model.removedRemoteNames.isEmpty)
        await fixture.settle()
    }

    @Test("a remote can't be saved", arguments: [
        NamedCase("under a name another has", (name: "origin", url: "https://example.com/app.git")),
        NamedCase("without a name", (name: " ", url: "https://example.com/app.git")),
        NamedCase("without a URL", (name: "archive", url: "")),
    ])
    func settingsRefuses(_ testCase: NamedCase<(name: String, url: String)>) async throws {
        let (fixture, _) = try await makeFixture()
        let model = RepositorySettingsModel(repository: fixture.repository, app: fixture.app)
        await model.load()
        #expect(model.canSave)

        model.addRemote()
        model.remotes[2].name = testCase.value.name
        model.remotes[2].url = testCase.value.url

        #expect(!model.canSave)
        #expect(!(await model.save()))
        #expect(fixture.repository.gitState.remotes.all.map(\.name) == ["mirror", "origin"])

        // Taken off the list again, there's nothing in Save's way.
        model.removeRemote(model.remotes[2].id)
        #expect(model.canSave)
        #expect(model.removedRemoteNames.isEmpty)
        await fixture.settle()
    }

    @Test("a remote git refuses to add stays on the list with what failed; the rest is saved")
    func settingsKeepsWhatFailed() async throws {
        let (fixture, _) = try await makeFixture()
        let model = RepositorySettingsModel(repository: fixture.repository, app: fixture.app)
        await model.load()

        model.removeRemote(model.remotes[1].id)
        model.addRemote()
        model.remotes[1].name = "not a name"
        model.remotes[1].url = "https://example.com/app.git"

        #expect(!(await model.save()))

        #expect(model.errors.count == 1)
        #expect(fixture.repository.gitState.remotes.all.map(\.name) == ["origin"])
        #expect(model.removedRemoteNames.isEmpty)
        #expect(model.remotes.map(\.isNew) == [false, true])
        await fixture.settle()
    }
}

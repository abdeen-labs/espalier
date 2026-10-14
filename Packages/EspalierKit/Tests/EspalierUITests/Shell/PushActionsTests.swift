// Push (⌘P, Repository ▸ Push) never forces: on a diverged branch it fails
// as non-fast-forward and the remote keeps its commits. Force Push is its
// own command, offered only while a force push is possible, and asks first.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Push and Force Push", .offline, .hangGuard(minutes: 5)) @MainActor
struct PushActionsTests {
    /// A selected repository whose window's announcements go nowhere (the
    /// test process has no `NSApp` to post them through).
    private func makeFixture() async throws -> OperationsFixture {
        let fixture = try await makeOperationsFixture()
        fixture.context.announcer = Announcer(isListening: { false }, post: { _, _ in })
        return fixture
    }

    /// `main` with a commit of its own and one from another clone fetched:
    /// diverged from `origin/main`. Returns the other clone's commit.
    private func diverge(_ fixture: OperationsFixture) async throws -> String {
        let theirs = try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        try await commitFile(fixture.local, "mine.txt", "mine\n")
        try await fixture.git(["fetch", "-q"])
        await fixture.refresh()
        #expect(fixture.repository.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 1))
        return theirs
    }

    private func remoteTip(_ fixture: OperationsFixture) async throws -> String {
        JSCompat.trim(try await runGit(["rev-parse", "refs/heads/main"], fixture.remote))
    }

    @Test("on a diverged branch Push fails as non-fast-forward without asking, and the remote keeps its commits")
    func pushNeverForces() async throws {
        let fixture = try await makeFixture()
        let actions = fixture.context.actions
        // Up to date: Force Push isn't offered.
        #expect(actions.isHidden(.forcePush))
        #expect(!actions.canPerform(.forcePush))

        let theirs = try await diverge(fixture)
        #expect(!actions.isHidden(.forcePush))
        #expect(actions.canPerform(.forcePush))

        actions.perform(.push)
        await fixture.settle()

        let error = try #require(fixture.presenter.error)
        #expect(error.error.reason == .pushRejectedNonFastForward)
        #expect(fixture.presenter.confirmation == nil)
        #expect(try await remoteTip(fixture) == theirs)
    }

    @Test("Force Push asks first, then overwrites the remote branch")
    func forcePushAsks() async throws {
        let fixture = try await makeFixture()
        fixture.app.preferences.confirmForcePush = true
        let theirs = try await diverge(fixture)
        let mine = try await fixture.sha("HEAD")

        fixture.context.actions.perform(.forcePush)
        let asked = await fixture.confirmation()
        #expect(asked.confirmation.kind == .forcePush)
        #expect(try await remoteTip(fixture) == theirs)

        fixture.presenter.respond(to: asked.id, with: ConfirmationResponse(isConfirmed: true))
        await fixture.settle()
        #expect(fixture.presenter.error == nil)
        #expect(try await remoteTip(fixture) == mine)
    }
}

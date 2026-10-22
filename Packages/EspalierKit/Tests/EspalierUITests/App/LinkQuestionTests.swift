// A link's question through the external events bridge and the window's
// presenter: cancelled, the repository stays selected with nothing fetched
// or checked out; confirmed, the link runs again with the answer and its
// branch is fetched and checked out. A link that can't be acted on shows
// why.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Link questions", .offline, .hangGuard(minutes: 5)) @MainActor
struct LinkQuestionTests {
    @Test("a link's branch: cancelled, the repository stays selected with nothing fetched or checked out; confirmed, the branch is fetched and checked out")
    func branch() async throws {
        let fixture = try await makeOperationsFixture()
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "-b", "topic"], other)
        try await commitFile(other, "topic.txt", "topic\n")
        try await runGit(["push", "-q", "origin", "topic"], other)
        // `continueAfterClone` asks and presents as a link does, without
        // bringing Espalier to the front.
        let request = ExternalCloneRequest(action: OpenRepositoryFromURLAction(url: "https://github.com/octocat/app", branch: "topic"), pullRequest: nil)
        let id = fixture.repository.id

        let cancelled = Task {
            await ExternalEventsBridge.continueAfterClone(request, in: id, context: fixture.context)
        }
        let question = await fixture.confirmation()
        #expect(question.confirmation.kind == .checkoutLinkedBranch)
        fixture.presenter.respond(to: question.id, with: .cancelled)
        await cancelled.value
        #expect(fixture.app.selection == .repository(id))
        #expect(try await fixture.currentBranch() == "main")
        #expect(try await runGitAllowingFailure(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/topic"], fixture.local) != 0)

        let confirmed = Task {
            await ExternalEventsBridge.continueAfterClone(request, in: id, context: fixture.context)
        }
        fixture.presenter.respond(to: await fixture.confirmation().id, with: ConfirmationResponse(isConfirmed: true))
        await confirmed.value
        #expect(try await fixture.currentBranch() == "topic")
        await fixture.settle()
    }

    @Test("a link Espalier can't act on says why: an unknown link, and a branch the repository doesn't have")
    func unfulfilled() async throws {
        let fixture = try await makeOperationsFixture()
        await ExternalEventsBridge.present(.ignored("Espalier can't open this link: espalier://nothing"), in: fixture.context)
        let ignored = try #require(fixture.presenter.error)
        #expect(ignored.error.operation == .openLink)
        fixture.presenter.dismissError(ignored.id)
        #expect(fixture.presenter.error == nil)

        let request = ExternalCloneRequest(action: OpenRepositoryFromURLAction(url: "https://github.com/octocat/app", branch: "nope"), pullRequest: nil)
        let confirmed = Task {
            await ExternalEventsBridge.continueAfterClone(request, in: fixture.repository.id, context: fixture.context)
        }
        fixture.presenter.respond(to: await fixture.confirmation().id, with: ConfirmationResponse(isConfirmed: true))
        await confirmed.value
        let missing = try #require(fixture.presenter.error)
        #expect(missing.error.operation == .checkoutBranch)
        #expect(try await fixture.currentBranch() == "main")
        await fixture.settle()
    }
}

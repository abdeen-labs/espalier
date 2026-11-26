// The line under Commit and Push, which says what committing and pushing
// will do, shows only while there's something to commit: files included,
// or an empty commit.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Push caption presence", .offline, .hangGuard(minutes: 5)) @MainActor
struct PushCaptionPresenceTests {
    /// A published branch with nothing to push, Push After Committing on.
    private func makeFixture() async throws -> ChangesWindowFixture {
        let (local, _) = try await setupRepositoryWithRemote()
        let fixture = try await ChangesWindowFixture.make(local)
        fixture.repository.commit.setPushesAfterCommitting(true)
        return fixture
    }

    private func caption(_ fixture: ChangesWindowFixture) -> String? {
        ComposerContent.make(fixture.repository, app: fixture.app).button.pushCaption
    }

    @Test("with nothing to commit there's no line, though the button would push")
    func nothingToCommit() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.repository.changes.workingDirectory.files.isEmpty)
        #expect(ComposerContent.make(fixture.repository, app: fixture.app).button.pushes)
        #expect(caption(fixture) == nil)
    }

    @Test("a changed file included shows the line; none included, or an empty commit allowed, as committing would")
    func somethingToCommit() async throws {
        let fixture = try await makeFixture()
        try fixture.write("new.txt", "new\n")
        await fixture.refresh()
        #expect(try fixture.file("new.txt").isIncludedInCommit)
        #expect(caption(fixture) != nil)

        fixture.repository.changes.setIncluded([try fixture.file("new.txt").id], false)
        #expect(caption(fixture) == nil)

        fixture.repository.commit.options.allowEmpty = true
        #expect(caption(fixture) != nil)
    }
}

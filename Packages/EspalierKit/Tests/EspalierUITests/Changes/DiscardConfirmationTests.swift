// Discard All Changes… always asks, whatever the setting and however many
// files; several selected files always ask; one file asks as the setting
// says. Only the one-file question offers "Do not show this message again",
// the only one the setting governs. Repository ▸ Discard All Changes…, the
// Changes header menu, the sidebar, and History's working-copy menu all run
// the `.discardAllChanges` action.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Discard confirmations", .offline, .hangGuard(minutes: 5)) @MainActor
struct DiscardConfirmationTests {
    /// The confirmation the presenter shows, once it does.
    private func confirmation(_ fixture: ChangesWindowFixture) async -> PendingConfirmation {
        await waitUntil { fixture.context.presenter.confirmation != nil }
        return fixture.context.presenter.confirmation!
    }

    /// The alert's "Do not show this message again", if it has one.
    private func suppressionTitle(_ pending: PendingConfirmation) -> String? {
        pending.confirmation.alertContent.suppressionTitle
    }

    private func paths(_ fixture: ChangesWindowFixture) -> [String] {
        fixture.repository.changes.workingDirectory.files.map(\.path).sorted()
    }

    @Test("Discard All Changes asks every time, without the toggle: one file or several, the setting on or off")
    func discardAll() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            try Data("changed\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
            let fixture = try await ChangesWindowFixture.make(local)
            let presenter = fixture.context.presenter
            #expect(paths(fixture) == ["README.md"])

            // One file, the setting off: asks anyway.
            fixture.app.preferences.confirmDiscardChanges = false
            #expect(fixture.context.actions.canPerform(.discardAllChanges))
            fixture.context.actions.perform(.discardAllChanges)
            let one = await confirmation(fixture)
            #expect(one.confirmation.kind == .discardAllChanges)
            #expect(one.confirmation.title == "Discard All Changes?")
            #expect(suppressionTitle(one) == nil)
            presenter.respond(to: one.id, with: .cancelled)
            await fixture.context.actions.idle()
            await fixture.settle()
            #expect(paths(fixture) == ["README.md"])

            // Several files, the setting on: asks, and discards them.
            fixture.app.preferences.confirmDiscardChanges = true
            try fixture.write("notes.txt", "notes\n")
            await fixture.refresh()
            fixture.context.actions.perform(.discardAllChanges)
            let several = await confirmation(fixture)
            #expect(several.confirmation.kind == .discardAllChanges)
            #expect(suppressionTitle(several) == nil)
            presenter.respond(to: several.id, with: ConfirmationResponse(isConfirmed: true))
            await fixture.context.actions.idle()
            await fixture.settle()
            #expect(paths(fixture).isEmpty)
            #expect(try String(contentsOfFile: POSIXPath.join(local.path, "README.md"), encoding: .utf8) == "# README\n")
            #expect(presenter.error == nil)
            #expect(fixture.app.preferences.confirmDiscardChanges)
        }
    }

    @Test("several selected files always ask, without the toggle; one file asks as the setting says, with it")
    func discardSelected() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let presenter = fixture.context.presenter
            let controller = ChangesController(context: fixture.context, repository: fixture.repository)
            #expect(paths(fixture) == ["LICENSE", "README.md", "Sources/App/Loader.swift"])

            // Several of them, the setting on: no toggle, and ticking it
            // anyway changes nothing.
            controller.discard([try fixture.file("README.md"), try fixture.file("Sources/App/Loader.swift")])
            let several = await confirmation(fixture)
            #expect(several.confirmation.kind == .discardChanges)
            #expect(suppressionTitle(several) == nil)
            presenter.respond(to: several.id, with: ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
            await waitUntil { paths(fixture) == ["LICENSE"] }
            #expect(fixture.app.preferences.confirmDiscardChanges)

            // Several, the setting off: asks all the same.
            try fixture.write("a.txt", "a\n")
            try fixture.write("b.txt", "b\n")
            await fixture.refresh()
            fixture.app.preferences.confirmDiscardChanges = false
            controller.discard([try fixture.file("a.txt"), try fixture.file("b.txt")])
            let severalOff = await confirmation(fixture)
            #expect(severalOff.confirmation.kind == .discardChanges)
            #expect(suppressionTitle(severalOff) == nil)
            presenter.respond(to: severalOff.id, with: .cancelled)
            await fixture.settle()

            // One file, the setting on: asks, with the toggle, which turns
            // the setting off.
            fixture.app.preferences.confirmDiscardChanges = true
            controller.discard([try fixture.file("a.txt")])
            let one = await confirmation(fixture)
            #expect(one.confirmation.kind == .discardChanges)
            #expect(suppressionTitle(one) == AlertContent.doNotShowAgain)
            presenter.respond(to: one.id, with: ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
            await waitUntil { paths(fixture) == ["LICENSE", "b.txt"] }
            #expect(!fixture.app.preferences.confirmDiscardChanges)

            // One file, the setting off: discarded at once.
            controller.discard([try fixture.file("b.txt")])
            await waitUntil { paths(fixture) == ["LICENSE"] || presenter.confirmation != nil }
            #expect(presenter.confirmation == nil)
            #expect(paths(fixture) == ["LICENSE"])
            await fixture.settle()
            #expect(presenter.error == nil)
        }
    }
}

// Settings ▸ Git against real git with an isolated global configuration.
// Values are written when committed; invalid ones never are; a lock file in
// the way is explained inline, deleted, and the write tried again.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings ▸ Git", .offline) @MainActor
struct GitPaneTests {
    /// The global configuration as git reads it now.
    private func configured(_ app: AppModel) async throws -> GlobalGitSettings {
        try await app.loadGlobalGitSettings()
    }

    private func model(_ app: AppModel, accounts: [Account] = []) -> (GitSettingsModel, WindowPresenter) {
        let (context, _) = SettingsFixtures.context(app)
        return (GitSettingsModel(app: app, presenter: context.presenter, accounts: accounts), context.presenter)
    }

    @Test("shows the global configuration")
    func loads() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: "joe@example.com")
            try await app.setDefaultBranchForNewRepositories("trunk")

            let (settings, _) = model(app)
            #expect(settings.loadState == .loading)
            await settings.load()
            #expect(settings.loadState == .loaded)
            #expect(settings.name == "Joe Bloggs")
            // Without account emails, the address is a field of its own.
            #expect(!settings.showsEmailPopUp)
            #expect(settings.showsEmailField)
            #expect(settings.otherEmail == "joe@example.com")
            #expect(settings.branchChoice == .other)
            #expect(settings.otherBranch == "trunk")
            #expect(settings.attribution == nil)
        }
    }

    @Test("the name is written when committed; invalid and empty names never are")
    func name() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: nil)
            let (settings, _) = model(app)
            await settings.load()

            settings.name = "Joe Q. Bloggs"
            await settings.commitName()
            #expect(try await configured(app).name == "Joe Q. Bloggs")

            // Only characters git strips: shown, never written.
            settings.name = " .,:;<>\"'\\ "
            #expect(settings.nameProblem != nil)
            await settings.commitName()
            #expect(try await configured(app).name == "Joe Q. Bloggs")

            // Clearing it puts the configured name back.
            settings.name = ""
            #expect(settings.nameProblem == nil)
            await settings.commitName()
            #expect(settings.name == "Joe Q. Bloggs")
            #expect(try await configured(app).name == "Joe Q. Bloggs")
        }
    }

    @Test("an account's email is written when picked; Other is written when committed")
    func emails() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let (settings, _) = model(app, accounts: [SettingsFixtures.dotComAccount])
            await settings.load()

            // Nothing configured: "None", and the account's login suggested.
            #expect(settings.emailChoice == .none)
            #expect(settings.suggestedName == "joe")
            #expect(settings.emailChoices.map(\.email) == ["joe@example.com", "1234+joe@users.noreply.github.com"])
            #expect(try await configured(app).email == nil)

            await settings.selectEmail(.account("1234+joe@users.noreply.github.com"))
            #expect(try await configured(app).email == "1234+joe@users.noreply.github.com")

            // Other starts from the current address; nothing is written
            // until a new one is committed.
            await settings.selectEmail(.other)
            #expect(settings.otherEmail == "1234+joe@users.noreply.github.com")
            settings.otherEmail = "  joe@elsewhere.example.com "
            #expect(settings.attribution?.isAttributable == false)
            #expect(try await configured(app).email == "1234+joe@users.noreply.github.com")
            await settings.commitOtherEmail()
            #expect(settings.otherEmail == "joe@elsewhere.example.com")
            #expect(try await configured(app).email == "joe@elsewhere.example.com")

            // An empty address puts the configured one back.
            settings.otherEmail = "   "
            await settings.commitOtherEmail()
            #expect(settings.otherEmail == "joe@elsewhere.example.com")
            #expect(try await configured(app).email == "joe@elsewhere.example.com")

            // An account's address typed under Other is recognized.
            settings.otherEmail = "joe@example.com"
            #expect(settings.attribution?.isAttributable == true)

            // Loading again shows a configured account address in the
            // pop-up, matched without regard to case.
            try await app.setGlobalGitAuthor(name: nil, email: "JOE@example.com")
            await settings.load()
            #expect(settings.emailChoice == .account("joe@example.com"))
            #expect(!settings.showsEmailField)
        }
    }

    @Test("main and master are written when picked; another name as git allows it")
    func defaultBranch() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let (settings, _) = model(app)
            await settings.load()
            #expect(settings.branchChoice == .main)

            await settings.selectBranch(.master)
            #expect(try await configured(app).defaultBranch == "master")

            // Other shows the field; nothing is written until it's
            // committed, then the field shows the name saved.
            await settings.selectBranch(.other)
            #expect(try await configured(app).defaultBranch == "master")
            settings.otherBranch = "release candidate"
            let sanitized = sanitizedRefName("release candidate")
            #expect(settings.branchNameMessage?.isError == false)
            await settings.commitOtherBranch()
            #expect(try await configured(app).defaultBranch == sanitized)
            #expect(settings.otherBranch == sanitized)
            #expect(settings.branchNameMessage == nil)

            // A name with nothing valid in it is never written.
            settings.otherBranch = "..."
            #expect(sanitizedRefName("...").isEmpty)
            #expect(settings.branchNameMessage?.isError == true)
            await settings.commitOtherBranch()
            #expect(try await configured(app).defaultBranch == sanitized)

            await settings.selectBranch(.main)
            #expect(try await configured(app).defaultBranch == "main")
        }
    }

    @Test("a lock file in the way is explained, deleted, and the write tried again")
    func lockFile() async throws {
        try await withIsolatedGitConfig { configPath in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let (settings, presenter) = model(app)
            await settings.load()

            let lockPath = configPath + ".lock"
            try Data().write(to: URL(filePath: lockPath))
            settings.name = "Joe Bloggs"
            await settings.commitName()
            await settings.selectBranch(.master)

            #expect(settings.lockFile != nil)
            #expect(presenter.error == nil)
            #expect(try await configured(app).name == nil)

            // Both writes the lock stopped are tried again.
            await settings.deleteLockFileAndRetry()
            #expect(settings.lockFile == nil)
            #expect(!FileManager.default.fileExists(atPath: lockPath))
            #expect(try await configured(app).name == "Joe Bloggs")
            #expect(try await configured(app).defaultBranch == "master")
        }
    }

    @Test("Edit Global Git Config… shows the editor's error, with its recoveries")
    func editGlobalConfig() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let (settings, presenter) = model(app)
            // No editor is installed in tests.
            await settings.editGlobalConfig()
            let error = try #require(presenter.error?.error)
            #expect(error.operation == .openInEditor)
            #expect(error.recoveries.count == 1)
            if case .downloadSuggestedEditor? = error.recoveries.first {} else {
                Issue.record("Expected the suggested editor's download, got \(error.recoveries)")
            }
            #expect(harness.launcher.launched.isEmpty)
        }
    }

    @Test("reappearing reloads only after the writes made as the pane went away")
    func reloadAfterWrites() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: nil)
            let (settings, _) = model(app)
            await settings.load()

            // As the pane does: the commit starts as it disappears, the
            // reload as it appears again.
            settings.name = "Joe Q. Bloggs"
            let commit = Task { await settings.commitAll() }
            let reload = Task { await settings.load() }
            await commit.value
            await reload.value
            #expect(settings.name == "Joe Q. Bloggs")
            #expect(try await configured(app).name == "Joe Q. Bloggs")
        }
    }

    @Test("committing every field when the pane goes away writes what changed")
    func commitAll() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let (settings, _) = model(app)
            await settings.load()
            settings.name = "Joe Bloggs"
            settings.otherEmail = "joe@example.com"
            settings.branchChoice = .other
            settings.otherBranch = "develop"
            await settings.commitAll()
            let written = try await configured(app)
            #expect(written == GlobalGitSettings(name: "Joe Bloggs", email: "joe@example.com", defaultBranch: "develop"))
        }
    }
}

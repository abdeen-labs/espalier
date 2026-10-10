// These drive loading and saving a repository's own author against a real
// repository and an isolated global configuration, including switching to
// the global config when only one value is set, and refusing an empty
// value.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Repository Git config", .offline) @MainActor
struct RepositoryGitConfigTests {
    @Test("loads the global author when the repository has none of its own, and its own when it has either")
    func loads() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("user.name", "Global Name")
            try await setGlobalConfigValue("user.email", "global@example.com")
            let local = try await setupTwoCommitRepo()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)

            let global = try await model.loadGitAuthor()
            #expect(global == RepositoryGitAuthor(localName: nil, localEmail: nil, globalName: "Global Name", globalEmail: "global@example.com"))
            #expect(global.location == .global)
            #expect(global.name(for: .local) == "Global Name")
            #expect(global.email(for: .local) == "global@example.com")

            try await runGit(["config", "user.email", "local@example.com"], local)
            let own = try await model.loadGitAuthor()
            #expect(own.location == .local)
            #expect(own.name(for: .local) == "")
            #expect(own.email(for: .local) == "local@example.com")
            #expect(own.name(for: .global) == "Global Name")
            await app.idle()
        }
    }

    @Test("a local config writes the values that differ, and the repository's author reloads")
    func savesLocal() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("user.name", "Global Name")
            try await setGlobalConfigValue("user.email", "global@example.com")
            let local = try await setupTwoCommitRepo()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            let loaded = try await model.loadGitAuthor()

            try await model.saveGitAuthor(.local, name: "Local Name", email: "local@example.com", loaded: loaded)

            #expect(try await getConfigValue(local, "user.name", onlyLocal: true) == "Local Name")
            #expect(try await getConfigValue(local, "user.email", onlyLocal: true) == "local@example.com")
            #expect(try await getGlobalConfigValue("user.name") == "Global Name")
            let reloaded = try await model.loadGitAuthor()
            #expect(reloaded.location == .local)

            // Only what changed is written: the name alone.
            try await runGit(["config", "user.email", "edited@example.com"], local)
            try await model.saveGitAuthor(.local, name: "Renamed", email: "local@example.com", loaded: reloaded)
            #expect(try await getConfigValue(local, "user.name", onlyLocal: true) == "Renamed")
            #expect(try await getConfigValue(local, "user.email", onlyLocal: true) == "edited@example.com")
            await app.idle()
        }
    }

    @Test("switching to the global config removes the repository's own values, only those it has")
    func savesGlobal() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await setupTwoCommitRepo()
            try await runGit(["config", "user.email", "local@example.com"], local)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            let loaded = try await model.loadGitAuthor()
            #expect(loaded.location == .local)

            // Only the value that is set is unset: unsetting user.name, which
            // isn't set, would make git exit 5.
            try await model.saveGitAuthor(.global, name: "", email: "", loaded: loaded)

            #expect(try await getConfigValue(local, "user.email", onlyLocal: true) == nil)
            #expect(try await model.loadGitAuthor().location == .global)
            await app.idle()
        }
    }

    @Test("refuses an empty or invalid name and an empty email, and writes nothing when nothing changed")
    func validates() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await setupTwoCommitRepo()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            let loaded = try await model.loadGitAuthor()

            let empty = await #expect(throws: OperationError.self) {
                try await model.saveGitAuthor(.local, name: "  ", email: "joe@example.com", loaded: loaded)
            }
            #expect(empty?.message == "Enter a name for this repository's commits.")
            let invalid = await #expect(throws: OperationError.self) {
                try await model.saveGitAuthor(.local, name: "<>", email: "joe@example.com", loaded: loaded)
            }
            #expect(invalid?.message == invalidGitAuthorNameMessage)
            let noEmail = await #expect(throws: OperationError.self) {
                try await model.saveGitAuthor(.local, name: "Joe", email: "", loaded: loaded)
            }
            #expect(noEmail?.message == "Enter an email for this repository's commits.")
            #expect(try await getConfigValue(local, "user.name", onlyLocal: true) == nil)

            // Global with nothing of its own: nothing to do, no operation.
            try await model.saveGitAuthor(.global, name: "", email: "", loaded: loaded)
            #expect(model.runningOperations.isEmpty)
            await app.idle()
        }
    }
}

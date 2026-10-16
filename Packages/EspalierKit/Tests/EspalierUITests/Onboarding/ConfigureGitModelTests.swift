// The welcome flow's Configure Git keeps a name and email the global
// configuration already has: it starts on them, and Finish writes nothing
// unless the user picks the account or edits them. Without them it starts
// on the signed-in account's, and a choice made before the configuration
// loads stays.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Configure Git", .offline, .hangGuard(minutes: 5)) @MainActor
struct ConfigureGitModelTests {
    private nonisolated static let account = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    private nonisolated static let workName = "Joseph Bloggs"
    private nonisolated static let workEmail = "joseph.bloggs@work.example.com"

    /// Runs `body` with Configure Git's model, signed in to the account,
    /// over an isolated global configuration holding `name` and `email`
    /// (unset when nil); `body` gets the configuration's path.
    private func withModel(
        name: String?,
        email: String?,
        _ body: (ConfigureGitModel, String) async throws -> Void
    ) async throws {
        try await withIsolatedGitConfig { configPath in
            if let name {
                try await setGlobalConfigValue("user.name", name)
            }
            if let email {
                try await setGlobalConfigValue("user.email", email)
            }
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            await app.accounts.idle()
            try await harness.signIn([Self.account], to: app)
            await app.accounts.idle()
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app))
            try await body(model, configPath)
            await app.idle()
        }
    }

    private func globalAuthor() async throws -> (name: String?, email: String?) {
        (try await getGlobalConfigValue("user.name"), try await getGlobalConfigValue("user.email"))
    }

    @Test("a configured name and email are shown, and Finish leaves the configuration as it was")
    func keepsConfiguredAuthor() async throws {
        try await withModel(name: Self.workName, email: Self.workEmail) { model, configPath in
            let before = try Data(contentsOf: URL(filePath: configPath))
            await model.load()

            #expect(model.source == .manual)
            #expect(model.name == Self.workName)
            #expect(model.email == Self.workEmail)
            #expect(await model.finish())

            let author = try await globalAuthor()
            #expect(author.name == Self.workName)
            #expect(author.email == Self.workEmail)
            #expect(try Data(contentsOf: URL(filePath: configPath)) == before)
        }
    }

    @Test("picking the account over a configured author writes the account's name and email")
    func pickingAccountWritesIt() async throws {
        try await withModel(name: Self.workName, email: Self.workEmail) { model, _ in
            await model.load()
            model.source = .account
            #expect(await model.finish())

            let author = try await globalAuthor()
            #expect(author.name == "Joe Bloggs")
            #expect(author.email == lookupPreferredEmail(Self.account))
        }
    }

    @Test("editing a configured author writes the edit")
    func editingWritesIt() async throws {
        try await withModel(name: Self.workName, email: Self.workEmail) { model, _ in
            await model.load()
            model.manualEmail = "joseph@home.example.com"
            #expect(await model.finish())

            let author = try await globalAuthor()
            #expect(author.name == Self.workName)
            #expect(author.email == "joseph@home.example.com")
        }
    }

    @Test(
        "without both a name and an email configured, the account's author is the default and Finish writes it",
        arguments: [
            NamedCase<(name: String?, email: String?)>("nothing configured", (nil, nil)),
            NamedCase<(name: String?, email: String?)>("only a name", (workName, nil)),
            NamedCase<(name: String?, email: String?)>("only an email", (nil, workEmail)),
        ]
    )
    func defaultsToAccount(_ configured: NamedCase<(name: String?, email: String?)>) async throws {
        try await withModel(name: configured.value.name, email: configured.value.email) { model, _ in
            await model.load()

            #expect(model.source == .account)
            #expect(await model.finish())

            let author = try await globalAuthor()
            #expect(author.name == "Joe Bloggs")
            #expect(author.email == lookupPreferredEmail(Self.account))
        }
    }

    @Test("a choice made before the configuration loads stays")
    func choiceBeforeLoadStays() async throws {
        try await withModel(name: Self.workName, email: Self.workEmail) { model, _ in
            model.source = .account
            await model.load()

            #expect(model.source == .account)
            #expect(await model.finish())

            let author = try await globalAuthor()
            #expect(author.name == "Joe Bloggs")
            #expect(author.email == lookupPreferredEmail(Self.account))
        }
    }

    @Test("a name typed before the configuration loads stays, and the configured email fills the other field")
    func editBeforeLoadStays() async throws {
        try await withModel(name: Self.workName, email: Self.workEmail) { model, _ in
            model.source = .manual
            model.manualName = "Joe B."
            await model.load()

            #expect(model.source == .manual)
            #expect(model.name == "Joe B.")
            #expect(model.email == Self.workEmail)
        }
    }
}

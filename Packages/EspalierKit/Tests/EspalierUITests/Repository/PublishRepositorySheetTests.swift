// Ported from desktop/app/test/unit/ui/multi-account-pickers-test.tsx
//
// The Publish sheet's account: it starts on the repository's assigned
// account, and choosing another account forgets the organization chosen for
// the one before (desktop kept it, and published into it with the new
// account).

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Publish sheet", .offline, .hangGuard(minutes: 5)) @MainActor
struct PublishRepositorySheetTests {
    private nonisolated static func account(_ login: String, id: Int) -> Account {
        Account(
            login: login,
            endpoint: "https://api.github.com",
            token: "\(login)-token",
            emails: [],
            avatarURL: "",
            id: id,
            name: login
        )
    }

    private let mona = Self.account("mona", id: 1)
    private let hubot = Self.account("hubot", id: 2)

    /// A loaded app with mona and hubot signed in to GitHub.com, each in an
    /// organization of its own, and a repository without a remote.
    private func makeApp() async throws -> (AppHarness, AppModel, RepositoryModel) {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        try await harness.signIn([mona, hubot], to: app)
        let organizations = [
            "Bearer \(mona.token)": APIOrganization(id: 10, url: "https://api.github.com/orgs/mona-org", login: "mona-org", avatarURL: ""),
            "Bearer \(hubot.token)": APIOrganization(id: 20, url: "https://api.github.com/orgs/hubot-org", login: "hubot-org", avatarURL: ""),
        ]
        harness.gitHub.on("GET", "/user/orgs") { request in
            .json(encoding: organizations[request.header("Authorization") ?? ""].map { [$0] } ?? [])
        }
        let model = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        return (harness, app, model)
    }

    @Test("starts on the repository's assigned account, of several")
    func startsOnTheAssignedAccount() async throws {
        let (_, app, model) = try await makeApp()
        #expect(PublishRepositorySheetModel(repository: model, app: app).account == nil)

        let login = hubot.login
        app.updateRecord(model.id) { record in
            record.gitHubRepository = ModelFixtures.gitHubRepository()
            record.accountLogin = login
        }
        #expect(PublishRepositorySheetModel(repository: model, app: app).account?.identity == hubot.identity)
        await app.idle()
    }

    @Test("choosing another account forgets the organization chosen for the one before")
    func anotherAccountForgetsTheOrganization() async throws {
        // The harness serves the mock GitHub, so it lives to the end.
        let (harness, app, model) = try await makeApp()
        let sheet = PublishRepositorySheetModel(repository: model, app: app)
        sheet.chooseAccount(mona.identity)
        await sheet.loadOrganizations()
        sheet.organizationID = 10
        #expect(sheet.organization?.login == "mona-org")

        sheet.chooseAccount(hubot.identity)
        #expect(sheet.organizationID == nil)
        #expect(sheet.organization == nil)
        await sheet.loadOrganizations()
        #expect(sheet.organizations.map(\.login) == ["hubot-org"])
        #expect(sheet.organization == nil)

        // Choosing the account already chosen keeps its organization.
        sheet.organizationID = 20
        sheet.chooseAccount(hubot.identity)
        #expect(sheet.organization?.login == "hubot-org")
        await app.idle()
        withExtendedLifetime(harness) {}
    }
}

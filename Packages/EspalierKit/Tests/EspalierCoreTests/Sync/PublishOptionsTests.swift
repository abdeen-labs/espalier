// What the publish dialog loads. The organizations come from a mock
// GitHub; the description from the repository's .git/description.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Publish options", .offline) @MainActor
struct PublishOptionsTests {
    @Test("the account's organizations, sorted by login ignoring case; none when they can't be loaded")
    func organizations() async throws {
        let fixture = try await makeSelectedRepository()
        fixture.harness.gitHub.on("GET", "/user/orgs", respond: .json(encoding: [
            APIOrganization(id: 1, url: "", login: "zeta", avatarURL: ""),
            APIOrganization(id: 2, url: "", login: "Alpha", avatarURL: ""),
            APIOrganization(id: 3, url: "", login: "beta", avatarURL: ""),
        ]))
        let organizations = await fixture.model.sync.publishOrganizations(for: testAccount)
        #expect(organizations.map(\.login) == ["Alpha", "beta", "zeta"])

        fixture.harness.gitHub.on("GET", "/user/orgs", respond: .json(["message": "Server Error"], status: 500))
        #expect(await fixture.model.sync.publishOrganizations(for: testAccount).isEmpty)
        await fixture.app.idle()
    }

    @Test("the description is the repository's .git/description, unless it's git's placeholder")
    func description() async throws {
        let fixture = try await makeSelectedRepository()
        let file = POSIXPath.join(fixture.local.path, ".git", "description")
        try Data(DefaultGitDescription.utf8).write(to: URL(filePath: file))
        #expect(await fixture.model.sync.publishDescription() == "")
        try Data("A Git client".utf8).write(to: URL(filePath: file))
        #expect(await fixture.model.sync.publishDescription() == "A Git client")
        await fixture.app.idle()
    }
}

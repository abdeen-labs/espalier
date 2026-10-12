// The repository flows' sheet models: Clone's sources and the path a URL
// clones to, Create refusing a folder that's already a repository, Publish's
// destinations, and Open With's custom editor. They run on a hermetic app,
// with real repositories where they read one.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Repository sheet models", .offline) @MainActor
struct RepositorySheetModelTests {
    // MARK: Clone

    @Test("Clone: the sources, signed out and with two Enterprise accounts, and the path a URL clones to")
    func clone() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            app.preferences.lastCloneLocation = "/Users/joe/Developer"

            let signedOut = CloneSheetModel(app: app)
            #expect(signedOut.sources == [.gitHub, .url])

            let url = CloneSheetModel(app: app, initialURL: "https://github.com/joe/espalier")
            #expect(url.current.path == "/Users/joe/Developer/espalier")

            try await harness.signIn([RepositoryFixtures.dotComAccount, RepositoryFixtures.enterpriseAccount, RepositoryFixtures.secondEnterpriseAccount], to: app)
            let enterprise = CloneSheetModel(app: app, savedSource: .enterprise)
            #expect(enterprise.sources == [.gitHub, .enterprise, .url])
            await app.accounts.idle()
        }
    }

    // MARK: Create

    @Test("Create: a folder that's already a repository can't be created, as recorded and as the real check finds it")
    func create() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)

            // What the check found (EspalierCore's tests check it on real
            // folders): a repository.
            let base = "/Users/joe/Developer"
            let existing = CreateRepositorySheetModel(app: app, folder: "\(base)/espalier")
            existing.record(CreateRepositoryDestination(isRepository: true), for: "\(base)/espalier")
            #expect(!existing.canCreate)

            // The real check finds a repository's folder.
            let repository = try await setupTwoCommitRepo()
            let real = CreateRepositorySheetModel(app: app, folder: repository.path)
            await real.checkDestination()
            #expect(real.currentDestination.isRepository)
            #expect(!real.canCreate)
        }
    }

    // MARK: Publish

    @Test("Publish: GitHub.com and Enterprise, once both are signed in")
    func publish() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            let local = try setupEmptyRepository()
            let repository = try await harness.addAndSelect(local, to: app)

            try await harness.signIn([RepositoryFixtures.dotComAccount], to: app)
            try await harness.signIn([RepositoryFixtures.enterpriseAccount], to: app)
            let both = PublishRepositorySheetModel(repository: repository, app: app)
            #expect(both.destinations == [.gitHub, .enterprise])
            await app.idle()
            await app.accounts.idle()
        }
    }

    // MARK: Open With

    @Test("Open With: with no editors found, a custom editor, which can't open with a path that doesn't exist")
    func openWith() async throws {
        let harness = try AppHarness()
        let app = await RepositoryFixtures.app(harness)
        app.integrations.availableEditors = []
        let custom = OpenWithModel(integrations: app.integrations, path: "/Users/joe/Developer/espalier")
        #expect(custom.choice == .configure)
        custom.customPath = "/nonexistent/editor"
        custom.customArguments = "--wait"
        await custom.validate()
        #expect(!custom.canOpen)
    }
}

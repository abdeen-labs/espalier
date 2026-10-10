// The repository flows' screens, one image per layout: the rows in light
// and dark, the rest in light. States that differ only in words are
// RepositoryFlowTests' and Core's, and Add's, Git LFS's, and the quit
// guard's alerts are native. Leaf views take fixed values; the sheets'
// forms run on a hermetic app, with real repositories where they read one.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Repository snapshots", .offline) @MainActor
struct RepositorySnapshotTests {
    private let area = "Repository"

    // MARK: Rows, section, popover

    @Test("rows: the current repository, others with status, an owner, missing, cloning, status off")
    func rows() {
        let rows = VStack(alignment: .leading, spacing: Metrics.grid) {
            RepositoryRow(content: RepositoryFixtures.row("espalier", icon: .current, changed: 3, ahead: 2))
            RepositoryRow(content: RepositoryFixtures.row("desktop", behind: 14))
            RepositoryRow(content: RepositoryFixtures.row("website", subtitle: "octo-org", changed: 1200, ahead: 1, behind: 3))
            RepositoryRow(content: RepositoryFixtures.row("website", subtitle: "~/Developer/forks"))
            RepositoryRow(content: RepositoryFixtures.row("dotfiles", icon: .missing, showsStatus: false))
            RepositoryRow(content: RepositoryFixtures.row("swift", icon: .cloning(progress: 0)))
            RepositoryRow(content: RepositoryFixtures.row("linux", icon: .cloning(progress: 0.42)))
            RepositoryRow(content: RepositoryFixtures.row("quiet", changed: 3, ahead: 2, showsStatus: false))
        }
        .padding(Metrics.insetMedium)
        .frame(width: 260)
        assertSnapshot(rows, named: "rows", area: area)
    }

    @Test("the popover: worktrees, Recent and owners; no repositories")
    func popover() {
        let worktrees = [
            WorktreePopoverRow(path: "/Users/joe/Developer/espalier", name: "espalier", detail: "main", isLocked: false, isCurrent: true),
            WorktreePopoverRow(path: "/Users/joe/Developer/espalier-login", name: "espalier-login", detail: "feature/login", isLocked: true, isCurrent: false),
        ]
        let groups = [
            RepositoryPopoverContent.Group(id: "0:recent", title: "Recent", rows: [
                RepositoryFixtures.row("desktop", behind: 14),
                RepositoryFixtures.row("website", subtitle: "octo-org"),
            ]),
            RepositoryPopoverContent.Group(id: "1:dotcom:joe", title: "joe", rows: [
                RepositoryFixtures.row("espalier", icon: .current, changed: 3, ahead: 2),
                RepositoryFixtures.row("dotfiles"),
            ]),
            RepositoryPopoverContent.Group(id: "3:other", title: "Other", rows: [
                RepositoryFixtures.row("notes", icon: .missing, showsStatus: false),
                RepositoryFixtures.row("swift", icon: .cloning(progress: 0.3)),
            ]),
        ]
        let content = RepositoryPopoverContent(worktrees: worktrees, groups: groups, hasRepositories: true)
        assertSnapshot(
            RepositoryPopoverView(content: content, filter: .constant(""), highlighted: .constant(.entry(groups[1].rows[1].id))),
            named: "popover",
            area: area,
            appearances: [.light]
        )
        assertSnapshot(
            RepositoryPopoverView(content: RepositoryPopoverContent(worktrees: [], groups: [], hasRepositories: false), filter: .constant(""), highlighted: .constant(nil)),
            named: "popover-empty",
            area: area,
            appearances: [.light]
        )
    }

    // MARK: Get Started and the clone list

    @Test("Get Started: signed out, and signed in with the clone list")
    func getStarted() async throws {
        assertSnapshot(GetStartedActions().padding(Metrics.insetLarge * 2).frame(width: 440), named: "get-started-actions", area: area, appearances: [.light])

        let harness = try AppHarness()
        let account = RepositoryFixtures.dotComAccount
        let app = await RepositoryFixtures.app(harness)
        try await harness.signIn([account], to: app)
        await RepositoryFixtures.loadRepositories(app, harness: harness, for: account)
        let context = RepositoryFixtures.context(app)
        assertSnapshot(
            GetStartedView().windowEnvironment(context),
            named: "get-started-signed-in",
            area: area,
            size: CGSize(width: 960, height: 560),
            appearances: [.light]
        )
        await app.accounts.idle()
    }

    @Test("the clone list: repositories by owner, and none")
    func cloneList() {
        func list(_ content: CloneableListContent, selection: String? = nil) -> some View {
            CloneableRepositoryListView(content: content, filter: .constant(""), selection: .constant(selection))
                .frame(width: 440, height: 240)
                .padding(Metrics.insetMedium)
        }
        let content = RepositoryFixtures.cloneListContent
        assertSnapshot(list(content, selection: "https://github.com/joe/desktop"), named: "clone-list", area: area, appearances: [.light])
        assertSnapshot(
            list(CloneableListContent(groups: [], emptyState: .noRepositories(login: "joe", endpoint: "GitHub.com"))),
            named: "clone-list-none",
            area: area,
            appearances: [.light]
        )
    }

    // MARK: Clone

    @Test("Clone: a URL whose folder has files, and GitHub.com's list; signed out and with two Enterprise accounts, the sources")
    func clone() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            app.preferences.lastCloneLocation = "/Users/joe/Developer"
            let context = RepositoryFixtures.context(app)

            let signedOut = CloneSheetModel(app: app)
            #expect(signedOut.sources == [.gitHub, .url])

            // A folder with files (on every Mac): the folder's warning.
            let url = CloneSheetModel(app: app, initialURL: "https://github.com/joe/espalier")
            #expect(url.current.path == "/Users/joe/Developer/espalier")
            url.setPath("/Library")
            await url.validatePath()
            #expect(url.current.problem == "This folder contains files. Git can only clone to empty folders.")
            assertSnapshot(CloneForm(model: url).windowEnvironment(context), named: "clone-url-problem", area: area, appearances: [.light])

            let account = RepositoryFixtures.dotComAccount
            try await harness.signIn([account, RepositoryFixtures.enterpriseAccount, RepositoryFixtures.secondEnterpriseAccount], to: app)
            await RepositoryFixtures.loadRepositories(app, harness: harness, for: account)
            let signedIn = CloneSheetModel(app: app, savedSource: .gitHub)
            signedIn.select("https://github.com/octo-org/website", url: "https://github.com/octo-org/website.git")
            assertSnapshot(CloneForm(model: signedIn).windowEnvironment(context), named: "clone-github", area: area, appearances: [.light])

            let enterprise = CloneSheetModel(app: app, savedSource: .enterprise)
            #expect(enterprise.sources == [.gitHub, .enterprise, .url])
            await app.accounts.idle()
        }
    }

    // MARK: Create

    @Test("Create: empty; filled, with the README warning; a failure; an existing repository can't be created")
    func create() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            let base = "/Users/joe/Developer"

            let empty = CreateRepositorySheetModel(app: app)
            empty.basePath = base
            assertSnapshot(CreateRepositoryForm(model: empty), named: "create-empty", area: area, appearances: [.light])

            // What the checks found (EspalierCore's tests check them on
            // real folders): a README, a repository.
            let filled = CreateRepositorySheetModel(app: app, folder: "\(base)/notes")
            filled.description = "My notes"
            filled.createsReadme = true
            filled.gitIgnore = "Swift"
            filled.license = "MIT License"
            filled.record(CreateRepositoryDestination(readmeExists: true), for: "\(base)/notes")
            assertSnapshot(CreateRepositoryForm(model: filled), named: "create-readme-warning", area: area, appearances: [.light])

            let existing = CreateRepositorySheetModel(app: app, folder: "\(base)/espalier")
            existing.record(CreateRepositoryDestination(isRepository: true), for: "\(base)/espalier")
            #expect(!existing.canCreate)

            // The real check finds a repository's folder.
            let repository = try await setupTwoCommitRepo()
            let real = CreateRepositorySheetModel(app: app, folder: repository.path)
            await real.checkDestination()
            #expect(real.currentDestination.isRepository)
            #expect(!real.canCreate)

            let failed = CreateRepositorySheetModel(app: app)
            failed.name = "locked"
            failed.basePath = base
            failed.problem = "Couldn't create a folder at this path. You may not have permission to create folders here."
            assertSnapshot(CreateRepositoryForm(model: failed), named: "create-problem", area: area, appearances: [.light])
        }
    }

    // MARK: Publish

    @Test("Publish: the fields with a sanitized name and organizations; both servers with an error")
    func publish() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            let local = try setupEmptyRepository()
            let repository = try await harness.addAndSelect(local, to: app)
            let context = RepositoryFixtures.context(app)

            try await harness.signIn([RepositoryFixtures.dotComAccount], to: app)
            harness.gitHub.on("GET", "/user/orgs", respond: .json(encoding: [
                APIOrganization(id: 1, url: "", login: "octo-org", avatarURL: ""),
                APIOrganization(id: 2, url: "", login: "acme", avatarURL: ""),
            ]))
            let fields = PublishRepositorySheetModel(repository: repository, app: app)
            fields.name = "my app \u{1F680}"
            fields.description = "An app"
            await fields.loadOrganizations()
            fields.organizationID = 1
            assertSnapshot(PublishRepositoryForm(model: fields).windowEnvironment(context), named: "publish-fields", area: area, appearances: [.light])

            try await harness.signIn([RepositoryFixtures.enterpriseAccount], to: app)
            let both = PublishRepositorySheetModel(repository: repository, app: app)
            #expect(both.destinations == [.gitHub, .enterprise])
            both.name = "espalier"
            both.problem = "Couldn't create the repository in octo-org. Check that octo-org doesn't already have a repository with this name, and that you can create repositories there."
            assertSnapshot(PublishRepositoryForm(model: both).windowEnvironment(context), named: "publish-error", area: area, appearances: [.light])
            await app.idle()
            await app.accounts.idle()
        }
    }

    // MARK: Repository Settings

    @Test("Repository Settings: each pane")
    func settings() async throws {
        try await withIsolatedGitConfig { _ in
            try await setGlobalConfigValue("user.name", "Joe Bloggs")
            try await setGlobalConfigValue("user.email", "joe@example.com")
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            let fixture = try await setupTwoCommitRepo()
            _ = try await runGit(["remote", "add", "origin", "https://github.com/joe/espalier.git"], fixture)
            try Data("*.o\nbuild/\n".utf8).write(to: URL(filePath: POSIXPath.join(fixture.path, ".gitignore")))
            let repository = try await harness.addAndSelect(fixture, to: app)

            let model = RepositorySettingsModel(repository: repository, app: app)
            await model.load()
            for pane in [RepositorySettingsPane.remote, .ignoredFiles, .gitConfig] {
                model.pane = pane
                assertSnapshot(RepositorySettingsForm(model: model), named: "settings-\(pane.rawValue)", area: area, appearances: [.light])
            }
            await app.idle()
        }
    }

    // MARK: Small sheets

    @Test("Alias: create")
    func alias() {
        assertSnapshot(
            AliasForm(content: AliasContent(repositoryName: "notes", hasAlias: false, isGitHubRepository: false), alias: .constant("notes")),
            named: "alias-create",
            area: area,
            appearances: [.light]
        )
    }

    @Test("Open With: an editor; a custom editor's problems")
    func openWith() async throws {
        let harness = try AppHarness()
        let app = await RepositoryFixtures.app(harness)
        app.integrations.availableEditors = [
            FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app"),
            FoundEditor(editor: "Visual Studio Code", path: "/Applications/Visual Studio Code.app"),
        ]
        let editors = OpenWithModel(integrations: app.integrations, path: "/Users/joe/Developer/espalier")
        assertSnapshot(OpenWithForm(model: editors), named: "open-with", area: area, appearances: [.light])

        app.integrations.availableEditors = []
        let custom = OpenWithModel(integrations: app.integrations, path: "/Users/joe/Developer/espalier")
        #expect(custom.choice == .custom)
        custom.customPath = "/nonexistent/editor"
        custom.customArguments = "--wait"
        await custom.validate()
        #expect(!custom.canOpen)
    }

    // MARK: Window states

    @Test("missing, unsafe, and cloning")
    func windowStates() {
        let size = CGSize(width: 640, height: 420)
        assertSnapshot(
            MissingRepositoryForm(content: MissingRepositoryContent(name: "espalier", kind: .missing(path: "/Users/joe/Developer/espalier", canCloneAgain: true))),
            named: "missing",
            area: area,
            size: size,
            appearances: [.light]
        )
        assertSnapshot(
            MissingRepositoryForm(content: MissingRepositoryContent(name: "shared", kind: .unsafe(path: "/Users/Shared/shared")), isWorking: true),
            named: "unsafe",
            area: area,
            size: size,
            appearances: [.light]
        )
        assertSnapshot(
            CloningForm(content: CloningContent(name: "desktop", progress: 0.42, description: "Receiving objects:  42% (4200/10000), 12.00 MiB | 4.00 MiB/s", phase: .cloning)),
            named: "cloning-progress",
            area: area,
            size: size,
            appearances: [.light]
        )
    }
}

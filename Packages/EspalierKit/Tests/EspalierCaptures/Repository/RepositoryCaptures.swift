// The repository flows' screens: the rows; the popover in its card, and
// empty; Get Started's actions, and signed in with the clone list; the
// clone list by owner, and none; Clone with a URL whose folder has files,
// and GitHub.com's list with two Enterprise accounts signed in too; Create
// empty, filled over a folder with a README, and failed; Publish with
// organizations, and to either server with an error; Repository Settings'
// panes; Alias; Open With; and the missing, unsafe, and cloning states.
// Leaf views take fixed values; the sheets' forms run on a hermetic app,
// with real repositories and folders where they read one.

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

@Suite("Repository", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryCaptures {
    private let area = "Repository"

    // MARK: Rows, popover

    @Test("rows: the current repository, others with status, an owner, a folder, missing, cloning, status off")
    func rows() {
        let rows = VStack(alignment: .leading, spacing: Metrics.grid) {
            RepositoryRow(content: RepositoryCaptureFixtures.row("espalier", icon: .current, changed: 3, ahead: 2))
            RepositoryRow(content: RepositoryCaptureFixtures.row("desktop", behind: 1_204))
            RepositoryRow(content: RepositoryCaptureFixtures.row("website", subtitle: "octo-org", changed: 1200, ahead: 1, behind: 3))
            RepositoryRow(content: RepositoryCaptureFixtures.row("website", subtitle: "~/Developer/forks"))
            RepositoryRow(content: RepositoryCaptureFixtures.row("dotfiles", icon: .missing, showsStatus: false))
            RepositoryRow(content: RepositoryCaptureFixtures.row("swift", icon: .cloning(progress: 0)))
            RepositoryRow(content: RepositoryCaptureFixtures.row("linux", icon: .cloning(progress: 0.42)))
            RepositoryRow(content: RepositoryCaptureFixtures.row("quiet", changed: 3, ahead: 2, showsStatus: false))
        }
        .padding(Metrics.insetMedium)
        .frame(width: 260)
        capture(rows, named: "rows", area: area)
    }

    @Test("the popover, in its card: the filter and Add, worktrees with New Worktree…, Recent and owners, a row highlighted; and no repositories")
    func popover() {
        let worktrees = [
            WorktreeRowContent(path: "/Users/joe/Developer/espalier", detail: "main", isMain: true, isCurrent: true, isLocked: false),
            WorktreeRowContent(path: "/Users/joe/Developer/espalier-login", detail: "feature/login", isMain: false, isCurrent: false, isLocked: true),
        ]
        let groups = [
            RepositoryPopoverContent.Group(id: "0:recent", title: "Recent", rows: [
                RepositoryCaptureFixtures.row("desktop", behind: 14),
                RepositoryCaptureFixtures.row("website", subtitle: "octo-org"),
            ]),
            RepositoryPopoverContent.Group(id: "1:dotcom:joe", title: "joe", rows: [
                RepositoryCaptureFixtures.row("espalier", icon: .current, changed: 3, ahead: 2),
                RepositoryCaptureFixtures.row("dotfiles"),
            ]),
            RepositoryPopoverContent.Group(id: "3:other", title: "Other", rows: [
                RepositoryCaptureFixtures.row("notes", icon: .missing, showsStatus: false),
                RepositoryCaptureFixtures.row("swift", icon: .cloning(progress: 0.3)),
            ]),
        ]
        let content = RepositoryPopoverContent(worktrees: worktrees, groups: groups, hasRepositories: true)
        let maxHeight = Metrics.Window.defaultHeight - Metrics.Toolbar.height - Metrics.insetLarge * 2
        capture(
            RepositoryCaptureFixtures.popoverCard {
                RepositoryPopoverView(
                    content: content,
                    filter: .constant(""),
                    highlighted: .constant(.entry(groups[1].rows[1].id)),
                    maxHeight: maxHeight,
                    newWorktree: {}
                )
            },
            named: "popover",
            area: area
        )
        capture(
            RepositoryCaptureFixtures.popoverCard {
                RepositoryPopoverView(
                    content: RepositoryPopoverContent(worktrees: [], groups: [], hasRepositories: false),
                    filter: .constant(""),
                    highlighted: .constant(nil),
                    maxHeight: maxHeight
                )
            },
            named: "popover-empty",
            area: area
        )
    }

    // MARK: Get Started and the clone list

    @Test("Get Started: the actions")
    func getStartedActions() {
        // As wide as its widest line: the actions' titles on one line.
        capture(GetStartedActions().padding(Metrics.insetLarge * 2), named: "get-started-actions", area: area)
    }

    @Test("Get Started: signed in, with the account's repositories loaded")
    func getStartedSignedIn() async throws {
        let harness = try AppHarness()
        let account = AccountCaptureFixtures.dotCom
        let app = try await AccountCaptureFixtures.app(harness, signedIn: [account])
        await RepositoryCaptureFixtures.loadRepositories(app, harness: harness, for: account)
        let context = AccountCaptureFixtures.context(app)
        capture(GetStartedView().windowEnvironment(context), named: "get-started-signed-in", area: area, size: CGSize(width: 960, height: 560))
        await app.idle()
    }

    @Test("the clone list: repositories by owner, one selected; none; and a load that failed")
    func cloneList() {
        func list(_ content: CloneableListContent, selection: String? = nil) -> some View {
            CloneableRepositoryListView(content: content, filter: .constant(""), selection: .constant(selection))
                .frame(width: 440, height: 240)
                .padding(Metrics.insetMedium)
        }
        let content = CloneableListContent(groups: groupRepositories(RepositoryCaptureFixtures.apiRepositories, login: "joe"))
        capture(list(content, selection: "https://github.com/joe/desktop"), named: "clone-list", area: area)
        capture(
            list(CloneableListContent(groups: [], emptyState: .noRepositories(login: "joe", endpoint: "GitHub.com"))),
            named: "clone-list-none",
            area: area
        )
        capture(
            list(CloneableListContent(groups: [], emptyState: .failed(endpoint: "GitHub.com"))),
            named: "clone-list-failed",
            area: area
        )
    }

    // MARK: Clone

    @Test("Clone: a URL whose folder has files")
    func cloneURLProblem() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness)
            let context = AccountCaptureFixtures.context(app)
            let folder = try createTempDirectory()
            try Data("# Notes\n".utf8).write(to: URL(filePath: POSIXPath.join(folder, "README.md")))
            app.preferences.lastCloneLocation = POSIXPath.dirname(folder)
            let model = CloneSheetModel(app: app, initialURL: "https://github.com/joe/espalier")
            model.setPath(folder)
            await model.validatePath()
            capture(CloneForm(model: model).windowEnvironment(context), named: "clone-url-problem", area: area)
            await app.idle()
        }
    }

    @Test("Clone: GitHub.com's list, a repository selected, with two Enterprise accounts signed in too")
    func cloneGitHub() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let account = AccountCaptureFixtures.dotCom
            let app = try await AccountCaptureFixtures.app(harness, signedIn: [account, AccountCaptureFixtures.enterprise, AccountCaptureFixtures.secondEnterprise])
            app.preferences.lastCloneLocation = "/Users/joe/Developer"
            await RepositoryCaptureFixtures.loadRepositories(app, harness: harness, for: account)
            let context = AccountCaptureFixtures.context(app)
            let model = CloneSheetModel(app: app, savedSource: .gitHub)
            model.select("https://github.com/octo-org/website", url: "https://github.com/octo-org/website.git")
            capture(CloneForm(model: model).windowEnvironment(context), named: "clone-github", area: area)
            await app.idle()
        }
    }

    // MARK: Create

    @Test("Create: empty; over a folder with files, plain and filled over its README, .gitignore, and LICENSE; a failure")
    func create() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness)
            let base = "/Users/joe/Developer"

            let empty = CreateRepositorySheetModel(app: app)
            empty.basePath = base
            capture(CreateRepositoryForm(model: empty), named: "create-empty", area: area)

            let notes = POSIXPath.join(try createTempDirectory(), "notes")
            try FileManager.default.createDirectory(atPath: POSIXPath.join(notes, "Drafts"), withIntermediateDirectories: true)
            for (name, text) in [("README.md", "# Notes\n"), (".gitignore", "*.tmp\n"), ("LICENSE", "All rights reserved.\n"), ("Drafts/ideas.md", "- one\n"), ("todo.txt", "write\n"), ("draft.tmp", "ignored\n")] {
                try Data(text.utf8).write(to: URL(filePath: POSIXPath.join(notes, name)))
            }
            let plain = CreateRepositorySheetModel(app: app, folder: notes)
            await plain.checkDestination()
            await plain.listExistingFiles()
            capture(CreateRepositoryForm(model: plain), named: "create-existing-files", area: area)

            let filled = CreateRepositorySheetModel(app: app, folder: notes)
            filled.description = "My notes"
            filled.createsReadme = true
            filled.gitIgnore = "Swift"
            filled.license = "MIT License"
            await filled.checkDestination()
            await filled.listExistingFiles()
            capture(CreateRepositoryForm(model: filled), named: "create-overwrite-warnings", area: area)

            let failed = CreateRepositorySheetModel(app: app)
            failed.name = "locked"
            failed.basePath = base
            failed.problem = "Couldn't create a folder at this path. You may not have permission to create folders here."
            capture(CreateRepositoryForm(model: failed), named: "create-problem", area: area)
            await app.idle()
        }
    }

    // MARK: Publish

    @Test("Publish: the fields with a sanitized name and organizations; both servers, with an error")
    func publish() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness)
            let repository = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            let context = AccountCaptureFixtures.context(app)

            try await harness.signIn([AccountCaptureFixtures.dotCom], to: app)
            harness.gitHub.on("GET", "/user/orgs", respond: .json(encoding: [
                APIOrganization(id: 1, url: "", login: "octo-org", avatarURL: ""),
                APIOrganization(id: 2, url: "", login: "acme", avatarURL: ""),
            ]))
            let fields = PublishRepositorySheetModel(repository: repository, app: app)
            fields.name = "my app \u{1F680}"
            fields.description = "An app"
            await fields.loadOrganizations()
            fields.organizationID = 1
            capture(PublishRepositoryForm(model: fields).windowEnvironment(context), named: "publish-fields", area: area)

            try await harness.signIn([AccountCaptureFixtures.enterprise], to: app)
            let both = PublishRepositorySheetModel(repository: repository, app: app)
            both.name = "espalier"
            both.problem = "Couldn't create the repository in octo-org. Check that octo-org doesn't already have a repository with this name, and that you can create repositories there."
            capture(PublishRepositoryForm(model: both).windowEnvironment(context), named: "publish-error", area: area)
            await app.idle()
            await app.accounts.idle()
        }
    }

    // MARK: Repository Settings

    @Test("Repository Settings: each pane, loaded from a repository with a remote, a .gitignore, and the global author")
    func settings() async throws {
        try await withIsolatedGitConfig { configPath in
            try Data("[user]\n\tname = Joe Bloggs\n\temail = joe@example.com\n".utf8).write(to: URL(filePath: configPath))
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness)
            let fixture = try await setupTwoCommitRepo()
            _ = try await runGit(["remote", "add", "origin", "https://github.com/joe/espalier.git"], fixture)
            try Data("*.o\nbuild/\n".utf8).write(to: URL(filePath: POSIXPath.join(fixture.path, ".gitignore")))
            let repository = try await harness.addAndSelect(fixture, to: app)

            let model = RepositorySettingsModel(repository: repository, app: app)
            await model.load()
            for pane in [RepositorySettingsPane.remote, .ignoredFiles, .gitConfig] {
                model.pane = pane
                capture(RepositorySettingsForm(model: model), named: "settings-\(pane.rawValue)", area: area)
            }
            await app.idle()
        }
    }

    // MARK: Small sheets

    @Test("Alias: create")
    func alias() {
        capture(
            AliasForm(content: AliasContent(repositoryName: "notes", hasAlias: false, isGitHubRepository: false), alias: .constant("notes")),
            named: "alias-create",
            area: area
        )
    }

    @Test("Open With: the installed editors, the one chosen in Settings selected")
    func openWith() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        app.integrations.availableEditors = [
            FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app"),
            FoundEditor(editor: "Visual Studio Code", path: "/Applications/Visual Studio Code.app"),
        ]
        app.integrations.selectEditor("Visual Studio Code")
        let editors = OpenWithModel(integrations: app.integrations, settings: app.preferences.integrations, path: "/Users/joe/Developer/espalier")
        capture(OpenWithForm(model: editors), named: "open-with", area: area)
    }

    // MARK: Window states

    @Test("missing, unsafe, and cloning")
    func windowStates() {
        let size = CGSize(width: 640, height: 420)
        capture(
            MissingRepositoryForm(content: MissingRepositoryContent(name: "espalier", kind: .missing(path: "/Users/joe/Developer/espalier", canCloneAgain: true))),
            named: "missing",
            area: area,
            size: size
        )
        capture(
            MissingRepositoryForm(content: MissingRepositoryContent(name: "shared", kind: .unsafe(path: "/Users/Shared/shared")), isWorking: true),
            named: "unsafe",
            area: area,
            size: size
        )
        capture(
            CloningForm(content: CloningContent(name: "desktop", progress: 0.42, description: "Receiving objects:  42% (4200/10000), 12.00 MiB | 4.00 MiB/s", phase: .cloning)),
            named: "cloning-progress",
            area: area,
            size: size
        )
    }
}

/// Fixed values for the repository flows' captures: repositories to clone,
/// rows, and a popover's card.
@MainActor
enum RepositoryCaptureFixtures {
    static let apiRepositories: [APIRepository] = [
        createMockAPIRepository(
            cloneURL: "https://github.com/joe/dotfiles.git",
            htmlURL: "https://github.com/joe/dotfiles",
            name: "dotfiles",
            owner: createMockAPIIdentity(id: 1234, login: "joe"),
            isPrivate: true
        ),
        createMockAPIRepository(
            cloneURL: "https://github.com/joe/desktop.git",
            htmlURL: "https://github.com/joe/desktop",
            name: "desktop",
            owner: createMockAPIIdentity(id: 1234, login: "joe"),
            fork: true,
            archived: true
        ),
        createMockAPIRepository(
            cloneURL: "https://github.com/octo-org/website.git",
            htmlURL: "https://github.com/octo-org/website",
            name: "website",
            owner: createMockAPIIdentity(id: 99, login: "octo-org", type: .organization)
        ),
    ]

    /// Loads `account`'s repositories to clone from the mock GitHub.
    static func loadRepositories(_ app: AppModel, harness: AppHarness, for account: Account) async {
        harness.gitHub.on("GET", "/user/repos", respond: .json(encoding: apiRepositories))
        app.accounts.apiRepositories.load(account)
        await app.accounts.apiRepositories.idle()
    }

    /// A repository row.
    static func row(
        _ title: String,
        icon: RepositoryRowContent.Icon = .other,
        subtitle: String? = nil,
        changed: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        showsStatus: Bool = true
    ) -> RepositoryRowContent {
        RepositoryRowContent(
            id: .repository(RepositoryID()),
            title: title,
            subtitle: subtitle,
            icon: icon,
            changedFileCount: changed,
            ahead: ahead,
            behind: behind,
            showsStatus: showsStatus,
            fullName: subtitle.map { "\($0)/\(title)" } ?? title,
            alias: nil,
            path: "/Users/joe/Developer/\(title)"
        )
    }

    /// `content` in a popover's card, as a popover shows it, with the
    /// margin its shadow draws in.
    static func popoverCard<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        PopoverCardView(model: PopoverCardModel {
            AnyView(content())
        })
    }
}

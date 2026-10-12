// The repository flows' logic against a hermetic app and real repositories:
// the popover's rows and groups, Add's results, the Clone
// sheet's fields and checks, cloning with its follow-ups and Retry, links
// that wait for their clone, Create, Publish, Repository Settings, Open
// With, and the quit guard's clones. Flows that would show an alert are
// checked through the values they show instead: offscreen, an alert has no
// window to wait on.

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

@Suite("Repository flows", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryFlowTests {
    // MARK: The popover

    @Test("the popover's rows: by title in their groups, the filter, status when it's on, a clone in progress")
    func popoverRows() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let octo = RepositoryRecord(path: "/Users/joe/Developer/website", gitHubRepository: gitHubRepoFixture(owner: "octo-org", name: "website"))
        let local = RepositoryRecord(path: "/Users/joe/forks/website")
        let alias = RepositoryRecord(path: "/Users/joe/Developer/zeta", alias: "Alpha")
        let plain = RepositoryRecord(path: "/Users/joe/Developer/beta")
        for record in [octo, local, alias, plain] {
            app.insertRecord(record)
        }
        app.setIndicator(RepositoryIndicator(aheadBehind: AheadBehind(ahead: 2, behind: 0), changedFilesCount: 3), for: plain.id)

        app.preferences.repositoryIndicatorsEnabled = true
        func rows(_ filter: String = "") -> [RepositoryRowContent] {
            RepositoryPopoverContent.make(app, filter: filter).groups.flatMap(\.rows)
        }
        let content = RepositoryPopoverContent.make(app, filter: "")
        #expect(content.groups.map(\.id) == ["1:dotcom:octo-org", "3:other"])
        #expect(rows().map(\.title) == ["website", "Alpha", "beta", "website"])
        let beta = rows()[2]
        #expect(beta.showsStatus && beta.changedFileCount == 3 && beta.ahead == 2)

        // The filter matches titles, owners, and names, ignoring case.
        #expect(rows("OCTO").map(\.title) == ["website"])
        #expect(rows("zeta").map(\.title) == ["Alpha"])

        app.preferences.repositoryIndicatorsEnabled = false
        #expect(!rows()[2].showsStatus)

        // A clone in progress is listed, with its ring.
        app.clones.clones.append(CloneTask(url: "https://github.com/joe/swift.git", path: "/Users/joe/Developer/swift"))
        let cloning = try #require(rows().first { $0.title == "swift" })
        #expect(cloning.icon == .cloning(progress: 0))
        app.clones.clones.removeAll()
    }

    @Test("the popover groups as desktop does, filters fuzzily, and lists the selected repository's worktrees")
    func popoverContent() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            for index in 1...8 {
                app.insertRecord(RepositoryRecord(path: "/Users/joe/Developer/repository-\(index)"))
            }
            app.insertRecord(RepositoryRecord(path: "/Users/joe/Developer/website", gitHubRepository: gitHubRepoFixture(owner: "octo-org", name: "website")))
            app.recentRepositoryIDs = [app.repositories[2].id]

            let content = RepositoryPopoverContent.make(app, filter: "")
            #expect(content.groups.map(\.id) == ["0:recent", "1:dotcom:octo-org", "3:other"])
            #expect(content.groups[0].rows.map(\.title) == ["repository-3"])
            #expect(content.worktrees.isEmpty)
            #expect(content.rowIDs.count == 10)

            // Fuzzy: "rpo8" finds "repository-8".
            #expect(RepositoryPopoverContent.make(app, filter: "rpo8").groups.flatMap(\.rows).map(\.title) == ["repository-8"])
            #expect(RepositoryPopoverContent.make(app, filter: "octo").groups.map(\.id) == ["1:dotcom:octo-org"])

            // A repository with one worktree lists none, unless Show
            // Worktrees revealed it; the popover opens on the selected
            // repository's row.
            let single = try await harness.addAndSelect(try await setupTwoCommitRepo(), to: app)
            let selected = RepositoryPopoverContent.make(app, filter: "")
            #expect(selected.worktrees.isEmpty)
            #expect(selected.currentRowID == .entry(.repository(single.id)))
            #expect(RepositoryPopoverContent.make(app, filter: "", revealingWorktreesOf: single.id).worktrees.map(\.isCurrent) == [true])

            // A repository with a linked worktree lists both, and the
            // popover opens on the window's worktree.
            let main = try await setupTwoCommitRepo()
            let linked = POSIXPath.join(try createTempDirectory(), "feature")
            _ = try await runGit(["worktree", "add", "-b", "feature", linked], main)
            _ = try await harness.addAndSelect(main, to: app)
            let withWorktrees = RepositoryPopoverContent.make(app, filter: "")
            #expect(withWorktrees.worktrees.map(\.name) == [POSIXPath.basename(main.path), "feature"])
            #expect(withWorktrees.worktrees.map(\.detail) == ["master", "feature"])
            #expect(withWorktrees.worktrees.map(\.isCurrent) == [true, false])
            let window = try #require(withWorktrees.worktrees.first)
            #expect(withWorktrees.currentRowID == .worktree(path: window.path))
            await app.idle()
        }
    }

    @Test("Copy Repository Name copies the GitHub repository's or the folder's name, never the alias")
    func copiedName() {
        let gitHub = RepositoryRecord(
            path: "/Users/joe/Developer/site",
            alias: "Work Site",
            gitHubRepository: gitHubRepoFixture(owner: "octo-org", name: "website")
        )
        #expect(RepositoryContextMenu.copiedName(gitHub) == "website")
        let local = RepositoryRecord(path: "/Users/joe/Developer/notes", alias: "Notes")
        #expect(RepositoryContextMenu.copiedName(local) == "notes")
    }

    // MARK: Add

    @Test("Add's alert: one folder offers to create a repository, a bare one says so, several are listed")
    func addAlerts() throws {
        var result = AddRepositoriesResult()
        #expect(AddRepositoryAlert(result) == nil)

        result.invalidPaths = ["/Users/joe/Downloads"]
        let one = try #require(AddRepositoryAlert(result))
        #expect(one == .createRepository(path: "/Users/joe/Downloads"))

        result.barePaths = result.invalidPaths
        #expect(AddRepositoryAlert(result) == .bareRepository(path: "/Users/joe/Downloads"))

        result.invalidPaths = ["/a", "/b"]
        result.invalidPathsMessage = "The following paths aren't Git repositories:\n\n- /a\n- /b"
        #expect(AddRepositoryAlert(result) == .invalidPaths(message: "The following paths aren't Git repositories:\n\n- /a\n- /b"))
    }

    @Test("adding selects the first repository added, else one already listed")
    func addSelects() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let context = RepositoryFixtures.context(app)
            let first = try setupEmptyRepository()
            let second = try setupEmptyRepository()

            await RepositoryActions.addRepositories([first.path, second.path], in: context)
            #expect(app.repositories.map(\.path) == [first.path, second.path])
            #expect(app.selection == .repository(app.repositories[0].id))

            app.select(.repository(app.repositories[1].id))
            await RepositoryActions.addRepositories([first.path], in: context)
            #expect(app.selection == .repository(app.repositories[0].id))
            #expect(AddRepositoryPanel.folderPath(URL(filePath: "/Users/joe/Developer/", directoryHint: .isDirectory)) == "/Users/joe/Developer")
            await app.idle()
        }
    }

    // MARK: Clone

    @Test("Clone's fields: the path follows the URL, each source keeps its own, and Clone needs a URL, a path, and no problem")
    func cloneFields() async throws {
        let harness = try AppHarness()
        let app = await RepositoryFixtures.app(harness)
        app.preferences.lastCloneLocation = "/Users/joe/Developer"

        let model = CloneSheetModel(app: app)
        #expect(model.source == .gitHub)
        #expect(!model.showsLocalPath)
        model.source = .url
        #expect(model.current.path == "/Users/joe/Developer")
        #expect(!model.canClone)

        model.setURL("https://github.com/desktop/desktop.git")
        #expect(model.current.path == "/Users/joe/Developer/desktop")
        model.setURL("octocat/Hello-World")
        #expect(model.current.path == "/Users/joe/Developer/Hello-World")
        #expect(model.canClone)
        model.setURL("")
        #expect(model.current.path == "/Users/joe/Developer")
        #expect(!model.canClone)

        // The starting folder has files, but there's nothing to say until a
        // URL is entered.
        model.setPath("/Library")
        model.setURL("https://example.com/repo.git")
        await model.validatePath()
        #expect(model.current.problem != nil)
        #expect(!model.canClone)

        // Each source keeps its own fields.
        model.source = .gitHub
        #expect(model.current.url.isEmpty)
        model.source = .url
        #expect(model.current.url == "https://example.com/repo.git")

        // Opened with a URL: on URL, the path following it.
        let opened = CloneSheetModel(app: app, initialURL: "https://github.com/joe/espalier.git", savedSource: .gitHub)
        #expect(opened.source == .url)
        #expect(opened.current.path == "/Users/joe/Developer/espalier")

        // The Enterprise source shows only with an Enterprise account; the
        // saved source falls back without one.
        #expect(CloneSheetModel(app: app, savedSource: .enterprise).source == .gitHub)
        try await harness.signIn([RepositoryFixtures.enterpriseAccount], to: app)
        #expect(CloneSheetModel(app: app, savedSource: .enterprise).source == .enterprise)
        await app.accounts.idle()
    }

    @Test("Clone refuses an owner/name no account can see, and resolves a URL as typed without an account")
    func cloneResolves() async throws {
        let harness = try AppHarness()
        let app = await RepositoryFixtures.app(harness)
        let base = try createTempDirectory()
        app.preferences.lastCloneLocation = base

        let alias = CloneSheetModel(app: app, initialURL: "octocat/Hello-World")
        #expect(await alias.prepareClone() == nil)
        #expect(alias.current.problem != nil)

        let url = CloneSheetModel(app: app, initialURL: "https://example.com/team/tool.git")
        let request = await url.prepareClone()
        #expect(request == CloneRequest(url: "https://example.com/team/tool.git", path: POSIXPath.join(base, "tool")))
    }

    @Test("cloning adds and selects the repository, then goes on with it")
    func cloneFlow() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let context = RepositoryFixtures.context(app)
            let source = try await setupTwoCommitRepo()
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")

            var continued: RepositoryID?
            await RepositoryActions.clone(CloneRequest(url: source.path, path: destination), in: context) { id in
                continued = id
            }
            let record = try #require(app.repositories.first)
            #expect(record.path == destination)
            #expect(continued == record.id)
            #expect(app.selection == .repository(record.id))
            #expect(app.clones.clones.isEmpty)
            await app.idle()
        }
    }

    @Test("a clone's error offers Retry Clone, which the clone flow runs itself; closing it chooses nothing")
    func cloneFailurePresentation() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let context = RepositoryFixtures.context(app)
        let retry = CloneRetry(request: CloneRequest(url: "https://github.com/joe/missing.git", path: "/Users/joe/Developer/missing"))
        let error = OperationError(
            .git(GitFailure(gitError: nil, message: "fatal: repository 'https://github.com/joe/missing.git/' not found", isRawMessage: true, exitCode: 128, stderr: "", args: ["clone"])),
            operation: .clone,
            retry: retry,
            recoveries: [.retry(retry)]
        )
        guard case .rawOutput(_, let recoveries) = error.presentation else {
            Issue.record("A clone's git output shows as raw output")
            return
        }
        #expect(recoveries.count == 1)
        // Offscreen the sheet has no window and closes at once: nothing is
        // chosen, so the flow ends.
        #expect(await RepositoryActions.chooseRecovery(for: error, in: context) == nil)
    }

    @Test("a link's clone opens Clone for its URL and keeps the link for afterwards")
    func linkClone() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let context = RepositoryFixtures.context(app)
        let request = ExternalCloneRequest(action: OpenRepositoryFromURLAction(url: "https://github.com/joe/espalier", branch: "dev"), pullRequest: nil)

        var opened: [String] = []
        let pending = context.state.featureState(PendingExternalClones.self) { PendingExternalClones() }
        context.actions.register(.cloneRepository) { action in
            if case .cloneRepository(let url?) = action {
                opened.append(url)
            }
        }
        RepositoryActions.presentClone(for: request, in: context)
        await context.actions.idle()
        #expect(opened == ["https://github.com/joe/espalier"])
        #expect(pending.requests["https://github.com/joe/espalier"] == request)

        // The real handler takes the link when Clone opens.
        RepositoryActions.register(into: context.actions, context: context)
        context.actions.perform(.cloneRepository(url: "https://github.com/joe/espalier"))
        await context.actions.idle()
        #expect(pending.requests.isEmpty)
    }

    @Test("a link's clone waits while an alert or a sheet shows, then Clone opens for its URL; links wait in order", .offline)
    func linkCloneWaits() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let context = RepositoryFixtures.context(app)
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        context.modals.window = window
        defer { withExtendedLifetime(window) {} }
        let pending = context.state.featureState(PendingExternalClones.self) { PendingExternalClones() }
        let first = ExternalCloneRequest(action: OpenRepositoryFromURLAction(url: "https://github.com/joe/first", branch: "dev"), pullRequest: nil)
        let second = ExternalCloneRequest(action: OpenRepositoryFromURLAction(url: "https://github.com/joe/second"), pullRequest: nil)

        // An error is showing.
        let content = AlertContent(title: "Fetch failed", message: "The remote hung up.", buttons: [AlertContent.Button("Close", role: .primary)])
        let alert = Task { await context.modals.alert(content, id: "error") }
        await waitUntil { context.modals.isPresenting }
        #expect(!context.actions.canPerform(.cloneRepository(url: first.url)))

        // Two links arrive meanwhile: nothing opens yet.
        await ExternalEventsBridge.present(.cloneRequested(first), in: context)
        await ExternalEventsBridge.present(.cloneRequested(second), in: context)
        #expect(!context.modals.isPresentingSheet(id: CloneSheet.sheetID))
        #expect(pending.waiting == [first.url, second.url])

        // The alert closes: Clone opens for the first link, which it takes.
        context.modals.dismissAlert(id: "error")
        _ = await alert.value
        await waitUntil { context.modals.isPresentingSheet(id: CloneSheet.sheetID) }
        #expect(pending.requests[first.url] == nil)
        // The second waits for Clone to close.
        #expect(pending.waiting == [second.url])
        #expect(pending.requests[second.url] == second)

        pending.stopWaiting()
        await app.idle()
    }

    @Test("Clone checks its folder again, and Create its README, when Espalier becomes active")
    func checksOnActivation() async throws {
        let harness = try AppHarness()
        let app = await RepositoryFixtures.app(harness)
        let folder = POSIXPath.join(try createTempDirectory(), "app")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let file = POSIXPath.join(folder, "README.md")
        try Data("# App\n".utf8).write(to: URL(filePath: file))

        let clone = CloneSheetModel(app: app, initialURL: "https://github.com/joe/app")
        clone.setPath(folder)
        await clone.validatePath()
        #expect(clone.current.problem != nil)
        let create = CreateRepositorySheetModel(app: app, folder: folder)
        await create.checkDestination()
        #expect(create.currentDestination.readmeExists)

        // The user switches to the Finder and empties the folder.
        app.setActive(false)
        let watchers = [
            Task { await clone.validateOnActivation() },
            Task { await create.checkOnActivation() },
        ]
        await Task.yield()
        try FileManager.default.removeItem(atPath: file)
        #expect(clone.current.problem != nil)

        app.setActive(true)
        await waitUntil { clone.current.problem == nil && !create.currentDestination.readmeExists }
        for watcher in watchers {
            watcher.cancel()
            await watcher.value
        }
        await app.idle()
    }

    // MARK: Create, Publish

    @Test("Create: opened for a folder, its name and parent, not remembered; creating closes on success and shows a failure in the sheet")
    func createModel() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let context = RepositoryFixtures.context(app)

            let prefilled = CreateRepositorySheetModel(app: app, folder: "/Users/joe/Developer/notes")
            #expect(prefilled.name == "notes")
            #expect(prefilled.basePath == "/Users/joe/Developer")
            #expect(!prefilled.remembersBasePath)

            let base = try createTempDirectory()
            let model = CreateRepositorySheetModel(app: app)
            model.basePath = base
            #expect(!model.canCreate)
            model.name = "app"
            model.createsReadme = true
            #expect(model.canCreate)
            let result = try #require(await model.create(presenter: context.presenter))
            #expect(result.failures.isEmpty)
            #expect(app.record(result.repositoryID)?.path == POSIXPath.join(base, "app"))
            #expect(model.problem == nil)

            let again = CreateRepositorySheetModel(app: app)
            again.basePath = base
            again.name = "app"
            await again.checkDestination()
            #expect(again.currentDestination.isRepository)
            #expect(!again.canCreate)

            let relative = CreateRepositorySheetModel(app: app)
            relative.basePath = "Developer"
            relative.name = "app"
            #expect(await relative.create(presenter: context.presenter) == nil)
            #expect(relative.problem != nil)
            await app.idle()
        }
    }

    @Test("Publish: Enterprise first only without GitHub.com, the sanitized name, and GitHub's error in the sheet")
    func publishModel() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await RepositoryFixtures.app(harness)
            let local = try await setupTwoCommitRepo()
            let repository = try await harness.addAndSelect(local, to: app)
            let context = RepositoryFixtures.context(app)

            #expect(PublishRepositorySheetModel(repository: repository, app: app).account == nil)
            try await harness.signIn([RepositoryFixtures.enterpriseAccount], to: app)
            let enterprise = PublishRepositorySheetModel(repository: repository, app: app)
            #expect(enterprise.destination == .enterprise)
            #expect(enterprise.destinations.isEmpty)

            try await harness.signIn([RepositoryFixtures.dotComAccount], to: app)
            let model = PublishRepositorySheetModel(repository: repository, app: app)
            #expect(model.destination == .gitHub)
            model.name = "my app"
            #expect(model.sanitizedName == "my-app")
            model.name = "\u{1F680}"
            #expect(model.sanitizedName == "-")
            model.name = ""
            #expect(!model.canPublish)

            model.name = "app"
            harness.gitHub.on("POST", "/user/repos", respond: .json(["message": "Repository creation failed."], status: 422))
            #expect(await !model.publish(presenter: context.presenter))
            #expect(model.problem != nil)
            #expect(try await getRemotes(local).isEmpty)
            await app.idle()
            await app.accounts.idle()
        }
    }

    // MARK: Repository Settings

    @Test("Repository Settings saves what changed, in desktop's order, and lists what failed")
    func settingsSave() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let fixture = try await setupTwoCommitRepo()
            _ = try await runGit(["remote", "add", "origin", "https://github.com/joe/old.git"], fixture)
            let repository = try await harness.addAndSelect(fixture, to: app)

            let model = RepositorySettingsModel(repository: repository, app: app)
            #expect(model.panes == [.remote, .ignoredFiles, .gitConfig])
            await model.load()
            #expect(model.ignoreText == nil)
            #expect(!model.ignoreTextHasChanged)
            model.remoteURL = "  https://github.com/joe/new.git "
            model.ignoreText = "build/\n"
            model.gitConfigLocation = .local
            model.authorName = "Local Name"
            model.authorEmail = "local@example.com"

            #expect(await model.save())
            #expect(try await getRemotes(fixture).first?.url == "https://github.com/joe/new.git")
            #expect(try String(contentsOfFile: POSIXPath.join(fixture.path, ".gitignore"), encoding: .utf8) == "build/\n")
            #expect(try await getConfigValue(fixture, "user.name", onlyLocal: true) == "Local Name")
            #expect(model.errors.isEmpty)

            // An invalid name stops Save.
            model.authorName = "<>"
            #expect(!model.canSave)
            await app.idle()
        }
    }

    @Test("Repository Settings' email offers the account's addresses; Other keeps the address for the field and checks it")
    func settingsEmail() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let fixture = try await setupTwoCommitRepo()
            let repository = try await harness.addAndSelect(fixture, to: app)
            try await harness.signIn([RepositoryFixtures.dotComAccount], to: app)
            app.updateRecord(repository.id) { $0.gitHubRepository = gitHubRepoFixture(owner: "joe", name: "espalier") }

            let model = RepositorySettingsModel(repository: repository, app: app)
            await model.load()
            model.gitConfigLocation = .local
            #expect(model.authorEmailChoices.map(\.email) == ["joe@example.com", "1234+joe@users.noreply.github.com"])

            // An account's address, matched without regard to case.
            model.authorEmail = "JOE@example.com"
            #expect(model.authorEmailSelection == .account("joe@example.com"))
            model.selectAuthorEmail(.account("1234+joe@users.noreply.github.com"))
            #expect(model.authorEmail == "1234+joe@users.noreply.github.com")
            #expect(model.authorEmailAttribution == nil)

            // Other keeps the address until another is typed, then checks it.
            model.selectAuthorEmail(.other)
            #expect(model.authorEmailSelection == .other)
            #expect(model.authorEmail == "1234+joe@users.noreply.github.com")
            #expect(model.authorEmailAttribution?.isAttributable == true)
            model.authorEmail = "joe@elsewhere.example.com"
            #expect(model.authorEmailAttribution?.isAttributable == false)

            // Picking an account's address leaves Other.
            model.selectAuthorEmail(.account("joe@example.com"))
            #expect(model.authorEmailSelection == .account("joe@example.com"))

            // The global config's values aren't checked.
            model.gitConfigLocation = .global
            #expect(model.authorEmailAttribution == nil)
            await app.idle()
            await app.accounts.idle()
        }
    }

    // MARK: Open With, the quit guard

    @Test("Open With opens the chosen editor once, and a custom one only when it's valid")
    func openWith() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let context = RepositoryFixtures.context(app)
        app.integrations.availableEditors = [FoundEditor(editor: "Xcode", path: "/Applications/Xcode.app")]
        let model = OpenWithModel(integrations: app.integrations, path: "/Users/joe/Developer/espalier")
        #expect(model.choice == .named("Xcode"))
        #expect(model.canOpen)

        model.choice = .configure
        #expect(!model.canOpen)
        model.customPath = "/bin/cat"
        await model.validate()
        #expect(model.canOpen)
        await model.open(presenter: context.presenter)
        #expect(harness.launcher.launched.count == 1)
    }

    @Test("Open with Default App opens the file by its exact name, and shows an error when nothing can open it")
    func openWithDefaultProgram() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        let context = RepositoryFixtures.context(app)
        let path = "/Users/joe/Developer/espalier/R\u{e9}sum\u{e9}.md"

        await context.actions.performAndWait(.openWithDefaultProgram(path: path))
        #expect(harness.workspace.openedURLs == [URL(exactFilePath: path)])
        #expect(context.presenter.error == nil)

        harness.workspace.opens = false
        await context.actions.performAndWait(.openWithDefaultProgram(path: "/Users/joe/Developer/espalier/data.unknown"))
        let presented = try #require(context.presenter.error)
        guard case .alert(_, let recoveries) = presented.error.presentation else {
            Issue.record("The failure isn't an alert")
            return
        }
        #expect(recoveries.isEmpty)
        await app.idle()
    }

    @Test("the quit guard asks while a clone runs")
    func quitGuardCounts() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        #expect(QuitGuard.reasons(app).isEmpty)
        app.clones.clones.append(CloneTask(url: "https://github.com/joe/espalier.git", path: "/Users/joe/Developer/espalier"))
        let reasons = QuitGuard.reasons(app)
        #expect(reasons.runningOperation == .clone)
        app.clones.clones[0].phase = .cancelling
        #expect(QuitGuard.reasons(app).isEmpty)
        app.clones.clones.removeAll()
    }
}

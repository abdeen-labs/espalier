// The welcome flow, Configure Git, and the Move to Applications prompt: Skip
// goes on to Configure Git, a sign-in does too, Finish writes only what
// changed and ends the flow, a lock file is offered for deletion, and Not
// Now saves "Do not show this message again". Git runs against an isolated
// global configuration; the app is never moved.

import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// Accounts for the welcome flow's tests.
enum OnboardingFixtures {
    /// A GitHub.com account with a verified address (and its private one).
    static let dotCom = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [
            APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public),
            APIEmail(email: "joe@unverified.example.com", verified: false, primary: false, visibility: .private),
        ],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    /// A GitHub Enterprise account without a name.
    static let enterprise = Account(
        login: "jbloggs",
        endpoint: "https://ghe.example.com/api/v3",
        token: "",
        emails: [APIEmail(email: "joe.bloggs@corp.example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 42,
        name: ""
    )
}

@Suite("Welcome", .offline, .hangGuard(minutes: 5)) @MainActor
struct OnboardingTests {
    private func configured(_ app: AppModel) async throws -> GlobalGitSettings {
        try await app.loadGlobalGitSettings()
    }

    // MARK: The flow

    @Test("Skip This Step and a sign-in go on to Configure Git; a cancelled sign-in stays; Back returns")
    func flow() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let flow = WelcomeFlow(app: app, presenter: WindowPresenter(app: app))
        #expect(flow.step == .start)
        #expect(flow.configureGit == nil)

        flow.signInFinished(nil)
        #expect(flow.step == .start)

        flow.skip()
        #expect(flow.step == .configureGit)
        let first = try #require(flow.configureGit)

        flow.back()
        #expect(flow.step == .start)
        #expect(flow.configureGit == nil)

        flow.signInFinished(OnboardingFixtures.dotCom)
        #expect(flow.step == .configureGit)
        // Configure Git starts afresh each time.
        #expect(flow.configureGit !== first)
        #expect(WelcomeFlow.enterpriseSignIn == SignInRequest(endpoint: "", reason: .user))
    }

    // MARK: Configure Git

    @Test("without an account: the global author fills the fields, and Finish writes what changed and ends the flow")
    func manual() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            try await app.setGlobalGitAuthor(name: "Joe Bloggs", email: "joe@old.example.com")
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(nil))
            #expect(model.source == .manual)
            #expect(model.account == nil)
            #expect(!model.canFinish)

            await model.load()
            #expect(model.manualName == "Joe Bloggs")
            #expect(model.manualEmail == "joe@old.example.com")
            #expect(model.attribution == nil)
            #expect(model.canFinish)
            #expect(model.exampleAuthor.name == "Joe Bloggs")

            model.manualEmail = "  joe@new.example.com "
            #expect(await model.finish())
            #expect(try await configured(app).name == "Joe Bloggs")
            #expect(try await configured(app).email == "joe@new.example.com")
            #expect(app.preferences.hasShownWelcomeFlow)
        }
    }

    @Test("with an account: its name and an address of its, or typed ones with the attribution check")
    func account() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(OnboardingFixtures.dotCom))
            await model.load()
            #expect(model.source == .account)
            #expect(model.accountChoiceTitle == "Use my GitHub account name and email address")
            #expect(model.name == "Joe Bloggs")
            #expect(model.emailChoices.map(\.email) == ["joe@example.com", "1234+joe@users.noreply.github.com"])
            #expect(model.accountEmail == "joe@example.com")
            #expect(model.attribution == nil)

            // Configure manually starts from the account's values.
            model.source = .manual
            #expect(model.manualName == "Joe Bloggs")
            #expect(model.manualEmail == "joe@example.com")
            #expect(model.attribution?.isAttributable == true)
            model.manualEmail = "joe@elsewhere.example.com"
            #expect(model.attribution?.message == "This email address doesn't match your GitHub account. Your commits won't be attributed to you.")

            model.source = .account
            model.accountEmail = "1234+joe@users.noreply.github.com"
            #expect(await model.finish())
            #expect(try await configured(app).name == "Joe Bloggs")
            #expect(try await configured(app).email == "1234+joe@users.noreply.github.com")
            #expect(app.preferences.hasShownWelcomeFlow)
        }
    }

    @Test("an Enterprise account without a name: its login, and the Enterprise wording")
    func enterprise() throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(OnboardingFixtures.enterprise))
        #expect(model.accountChoiceTitle == "Use my GitHub Enterprise account name and email address")
        #expect(model.name == "jbloggs")
        #expect(model.accountEmail == "joe.bloggs@corp.example.com")
    }

    @Test("a name git would reject can't be saved; empty fields are left alone")
    func validation() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(nil))
            await model.load()
            model.manualName = " .,:;<>\"'\\ "
            #expect(model.nameProblem == "The name can't be only spaces and punctuation.")
            #expect(!model.canFinish)
            #expect(await model.finish() == false)
            #expect(!app.preferences.hasShownWelcomeFlow)

            model.manualName = ""
            model.manualEmail = ""
            #expect(model.canFinish)
            #expect(await model.finish())
            #expect(try await configured(app).name == nil)
            #expect(try await configured(app).email == nil)
            #expect(app.preferences.hasShownWelcomeFlow)
        }
    }

    @Test("a lock file in the way is explained; deleting it finishes")
    func lockFile() async throws {
        try await withIsolatedGitConfig { configPath in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(nil))
            await model.load()
            model.manualName = "Joe Bloggs"
            model.manualEmail = "joe@example.com"
            let lockPath = configPath + ".lock"
            try Data().write(to: URL(filePath: lockPath))

            #expect(await model.finish() == false)
            let problem = try #require(model.lockFile)
            #expect(problem.path == lockPath)
            #expect(problem.message.hasPrefix("Couldn't update your Git configuration because a lock file already exists at "))
            #expect(!model.canFinish)
            #expect(!app.preferences.hasShownWelcomeFlow)

            await model.deleteLockFileAndRetry()
            #expect(model.lockFile == nil)
            #expect(!FileManager.default.fileExists(atPath: lockPath))
            #expect(try await configured(app).name == "Joe Bloggs")
            #expect(app.preferences.hasShownWelcomeFlow)
        }
    }

    // MARK: Move to Applications

    private func mover(inApplications: Bool = false, development: Bool = false, moved: MoveRecorder? = nil, failure: String? = nil) -> ApplicationsFolderMover {
        ApplicationsFolderMover(
            isInApplicationsFolder: { inApplications },
            isDevelopmentBuild: development,
            moveAndRelaunch: { () async throws(ApplicationsFolderMoveError) in
                moved?.count += 1
                if let failure {
                    throw ApplicationsFolderMoveError(message: failure)
                }
            }
        )
    }

    @Test("asks only outside the Applications folder, with the setting on, in a release build")
    func moveConditions() throws {
        let harness = try AppHarness()
        let preferences = harness.makeApp().preferences
        #expect(preferences.askToMoveToApplicationsFolder)
        #expect(MoveToApplicationsPrompt.shouldAsk(preferences, mover: mover()))
        #expect(!MoveToApplicationsPrompt.shouldAsk(preferences, mover: mover(inApplications: true)))
        #expect(!MoveToApplicationsPrompt.shouldAsk(preferences, mover: mover(development: true)))
        preferences.askToMoveToApplicationsFolder = false
        #expect(!MoveToApplicationsPrompt.shouldAsk(preferences, mover: mover()))
    }

    @Test("Not Now saves \"Do not show this message again\"; Move and Restart moves, and says why when it can't")
    func moveResponses() async throws {
        let harness = try AppHarness()
        let preferences = harness.makeApp().preferences
        let moved = MoveRecorder()
        var alerts: [AlertContent] = []
        let showAlert: @MainActor (AlertContent) async -> AlertResponse = { alert in
            alerts.append(alert)
            return AlertResponse(buttonIndex: 0)
        }

        await MoveToApplicationsPrompt.respond(AlertResponse(buttonIndex: 1), preferences: preferences, mover: mover(moved: moved), showAlert: showAlert)
        #expect(preferences.askToMoveToApplicationsFolder)
        await MoveToApplicationsPrompt.respond(AlertResponse(buttonIndex: 1, isSuppressed: true), preferences: preferences, mover: mover(moved: moved), showAlert: showAlert)
        #expect(!preferences.askToMoveToApplicationsFolder)
        #expect(moved.count == 0)

        await MoveToApplicationsPrompt.respond(AlertResponse(buttonIndex: 0), preferences: preferences, mover: mover(moved: moved), showAlert: showAlert)
        #expect(moved.count == 1)
        #expect(alerts.isEmpty)

        await MoveToApplicationsPrompt.respond(AlertResponse(buttonIndex: 0), preferences: preferences, mover: mover(moved: moved, failure: "Permission denied."), showAlert: showAlert)
        #expect(moved.count == 2)
        #expect(alerts == [MoveToApplicationsPrompt.failureAlert("Permission denied.")])
        #expect(alerts.first?.title == "Couldn't Move Espalier")
    }

    @Test("an Applications folder is the system's or any folder of that name")
    func applicationsFolders() {
        #expect(ApplicationsFolderMove.isInApplicationsFolder("/Applications/Espalier.app"))
        #expect(ApplicationsFolderMove.isInApplicationsFolder("/Applications/Developer/Espalier.app"))
        #expect(ApplicationsFolderMove.isInApplicationsFolder(NSHomeDirectory() + "/Applications/Espalier.app"))
        #expect(ApplicationsFolderMove.isInApplicationsFolder("/Volumes/Backup/Applications/Espalier.app"))
        #expect(!ApplicationsFolderMove.isInApplicationsFolder(NSHomeDirectory() + "/Downloads/Espalier.app"))
        #expect(!ApplicationsFolderMove.isInApplicationsFolder("/Users/joe/Developer/Espalier/DerivedData/Build/Products/Debug/Espalier.app"))
    }

    @Test("the move's destination is an app bundle's name in /Applications, never the folder itself")
    func moveDestination() {
        #expect(ApplicationsFolderMove.destination(for: NSHomeDirectory() + "/Downloads/Espalier.app") == "/Applications/Espalier.app")
        #expect(ApplicationsFolderMove.destination(for: "/Volumes/Espalier/Espalier Beta.app") == "/Applications/Espalier Beta.app")
        // What's there is replaced with rm -rf as an administrator: no name,
        // no app bundle's name, no destination.
        #expect(ApplicationsFolderMove.destination(for: "/") == nil)
        #expect(ApplicationsFolderMove.destination(for: "") == nil)
        #expect(ApplicationsFolderMove.destination(for: "/Users/joe/Downloads") == nil)
        #expect(ApplicationsFolderMove.destination(for: "/Users/joe/.app") == nil)
        #expect(ApplicationsFolderMove.destination(for: "/Users/joe/..app") == nil)
    }
}

/// Counts moves.
@MainActor
final class MoveRecorder {
    var count = 0
}

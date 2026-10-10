// Helpers for the preferences tests (preferences, integrations,
// capabilities, gitignore, global git settings).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// An app whose editors and shells are stand-ins: fake applications in a
/// temporary folder, found by bundle identifier, launched by a recording
/// launcher.
@MainActor
struct IntegrationsFixture {
    let harness: AppHarness
    let app: AppModel
    let launcher: RecordingLauncher
    /// Where the fake applications are.
    let applications: String

    var integrations: IntegrationsModel {
        app.integrations
    }

    /// The path of a fake application installed here.
    func applicationPath(_ name: String) -> String {
        POSIXPath.join(applications, name)
    }
}

/// An app with the editors and shells named (application name to bundle
/// identifier) installed as fake applications, loaded unless `load` is
/// false (then its launch lookup hasn't run).
@MainActor
func makeIntegrationsFixture(
    editors: [(name: String, bundleID: String)] = [],
    shells: [(name: String, bundleID: String, executable: String?)] = [],
    launcherFailure: SpawnError? = nil,
    load: Bool = true,
    prepare: (Preferences) -> Void = { _ in }
) async throws -> IntegrationsFixture {
    let harness = try AppHarness()
    let applications = try createTempDirectory(prefix: "espalier-apps-")
    var paths: [String: String] = [:]
    for editor in editors {
        paths[editor.bundleID] = try makeFakeApplication(in: applications, named: editor.name, bundleIdentifier: editor.bundleID)
    }
    for shell in shells {
        paths[shell.bundleID] = try makeFakeApplication(
            in: applications,
            named: shell.name,
            bundleIdentifier: shell.bundleID,
            executable: shell.executable
        )
    }

    let launcher = RecordingLauncher(failingWith: launcherFailure)
    var environment = harness.environment
    environment.editors = ExternalEditorLookup(locator: FakeApplicationLocator(paths))
    environment.shells = ShellLookup(locator: FakeApplicationLocator(paths))
    environment.launcher = launcher

    let app = AppModel(environment: environment)
    prepare(app.preferences)
    if load {
        await app.load()
        await app.integrations.launchIdle()
    }
    return IntegrationsFixture(harness: harness, app: app, launcher: launcher, applications: applications)
}

/// The command `open -a <app> <path>` launches an editor with.
func openApplicationCommand(_ application: String, _ arguments: [String]) -> LaunchCommand {
    LaunchCommand(executable: "/usr/bin/open", arguments: ["-a", application] + arguments, isDetached: true)
}

/// A GitHub account for tests.
func testAccount(
    login: String = "joe",
    endpoint: String = "https://api.github.com",
    id: Int = 1234,
    name: String = "Joe Bloggs",
    emails: [APIEmail] = []
) -> Account {
    Account(
        login: login,
        endpoint: endpoint,
        token: "",
        emails: emails,
        avatarURL: "",
        id: id,
        name: name,
        plan: nil
    )
}

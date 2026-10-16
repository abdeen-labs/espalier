// The welcome flow's steps: the first step, and Configure Git with a
// signed-in account's author, an author the global configuration already
// has, a typed address the account doesn't have, and a lock file that kept
// Finish from writing. Configure Git reads the global configuration (an
// isolated one, empty unless the capture fills it) before it's drawn.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Onboarding", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct OnboardingCaptures {
    private let area = "Onboarding"
    private let size = CGSize(width: 760, height: 640)

    @Test("Welcome: the first step")
    func start() {
        capture(WelcomeStart().frame(maxWidth: .infinity, maxHeight: .infinity), named: "start", area: area, size: size)
    }

    /// Configure Git signed in to `accounts`, over a global configuration
    /// holding `configured` (`user.name`, `user.email`), loaded, then
    /// changed by `edit`, which gets the global configuration's path.
    private func configureGit(
        named name: String,
        signedIn accounts: [Account],
        configured: (name: String, email: String)? = nil,
        size: CGSize? = nil,
        edit: (ConfigureGitModel, String) async throws -> Void = { _, _ in }
    ) async throws {
        try await withIsolatedGitConfig { configPath in
            if let configured {
                try await setGlobalConfigValue("user.name", configured.name)
                try await setGlobalConfigValue("user.email", configured.email)
            }
            let harness = try AppHarness()
            let app = try await AccountCaptureFixtures.app(harness, signedIn: accounts)
            let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app))
            await model.load()
            try await edit(model, configPath)
            capture(ConfigureGitStep(model: model).frame(maxWidth: .infinity, maxHeight: .infinity), named: name, area: area, size: size ?? self.size)
            await app.idle()
        }
    }

    @Test("Configure Git: the account's author")
    func account() async throws {
        try await configureGit(named: "configureGit-account", signedIn: [AccountCaptureFixtures.dotCom])
    }

    @Test("Configure Git: an author the global configuration already has")
    func configured() async throws {
        try await configureGit(
            named: "configureGit-configured",
            signedIn: [AccountCaptureFixtures.dotCom],
            configured: ("Joseph Bloggs", "joseph.bloggs@work.example.com")
        )
    }

    @Test("Configure Git: a typed address the account doesn't have")
    func manualMismatch() async throws {
        try await configureGit(named: "configureGit-manualMismatch", signedIn: [AccountCaptureFixtures.dotCom]) { model, _ in
            model.source = .manual
            model.manualEmail = "joe@elsewhere.example.com"
        }
    }

    @Test("Configure Git: signed out, typed, and a lock file that kept Finish from writing")
    func lockFile() async throws {
        try await configureGit(named: "configureGit-lockFile", signedIn: [], size: CGSize(width: 760, height: 760)) { model, configPath in
            model.manualName = "Joe Bloggs"
            model.manualEmail = "joe@example.com"
            try Data().write(to: URL(filePath: configPath + ".lock"))
            await model.finish()
            try #require(model.lockFile != nil)
        }
    }
}

// The welcome flow's steps, one image per layout: the first step in light
// and dark, Configure Git in light. Configure Git shows fixed values (it
// isn't loaded from git). Its other states differ only in words
// (OnboardingTests), and Move to Applications' prompts are native alerts.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Welcome snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct OnboardingSnapshotTests {
    private let area = "Onboarding"
    private let size = CGSize(width: 760, height: 640)

    @Test("Welcome: the first step")
    func start() {
        assertSnapshot(WelcomeStart().frame(maxWidth: .infinity, maxHeight: .infinity), named: "start", area: area, size: size)
    }

    private func configureGit(_ account: Account?, edit: (ConfigureGitModel) -> Void = { _ in }) throws -> some View {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let model = ConfigureGitModel(app: app, presenter: WindowPresenter(app: app), account: .some(account))
        model.isLoaded = true
        edit(model)
        return ConfigureGitStep(model: model, loadsOnAppear: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @Test("Configure Git: the account's author, a mismatched address, and a lock file")
    func configureGitStates() throws {
        assertSnapshot(try configureGit(OnboardingFixtures.dotCom), named: "configureGit-account", area: area, size: size, appearances: [.light])
        assertSnapshot(
            try configureGit(OnboardingFixtures.dotCom) { model in
                model.source = .manual
                model.manualEmail = "joe@elsewhere.example.com"
            },
            named: "configureGit-manualMismatch",
            area: area,
            size: size,
            appearances: [.light]
        )
        assertSnapshot(
            try configureGit(nil) { model in
                model.manualName = "Joe Bloggs"
                model.manualEmail = "joe@example.com"
                model.lockFile = .init(
                    path: "/Users/joe/.gitconfig.lock",
                    message: "Couldn't update your Git configuration because a lock file already exists at /Users/joe/.gitconfig.lock.\n\nAnother tool may be changing the configuration, or a Git process may have quit without removing the lock file. Delete the lock file and try again?"
                )
            },
            named: "configureGit-lockFile",
            area: area,
            size: CGSize(width: 760, height: 760),
            appearances: [.light]
        )
    }
}

// Fixtures for the Changes place's tests: repositories with changes, a
// window context, and fixed content values.

import AppKit
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

/// A loaded app with one selected repository and a window for it.
@MainActor
struct ChangesWindowFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    /// The repository on disk.
    let local: Repository

    /// Adds `local` to a new app signed in to `accounts`, selects it, and
    /// makes a window showing Changes.
    static func make(_ local: Repository, accounts: [Account] = []) async throws -> ChangesWindowFixture {
        let harness = try AppHarness()
        for account in accounts {
            try await harness.environment.accountsStore.addAccount(account)
            // The launch refresh of the accounts asks who they are.
            harness.gitHub.on("GET", "/user", respond: .json(encoding: createMockAPIFullIdentity(id: account.id, login: account.login)))
            harness.gitHub.on("GET", "/user/emails", respond: .json(encoding: account.emails))
        }
        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        context.state.select(.changes, in: repository.id)
        let fixture = ChangesWindowFixture(harness: harness, app: app, repository: repository, context: context, local: local)
        await fixture.settle()
        return fixture
    }

    /// Waits for refreshes, operations, and the loads that follow them.
    func settle() async {
        await app.idle()
        await repository.changes.diffIdle()
        await repository.commit.mostRecentLocalCommitIdle()
        await repository.stash.loadsIdle()
        await app.idle()
    }

    /// Refreshes the repository and waits.
    func refresh(_ scope: RefreshScope = .full) async {
        await repository.refresh(scope, reason: .user)
        await settle()
    }

    /// Writes `contents` to `path`.
    func write(_ path: String, _ contents: String) throws {
        try harness.write(path, contents, in: local)
    }

    /// Runs git in the repository.
    @discardableResult
    func git(_ args: [String]) async throws -> String {
        try await runGit(args, local)
    }

    /// The changed file at `path`.
    func file(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> WorkingDirectoryFileChange {
        try #require(repository.changes.workingDirectory.files.first { $0.path == path }, "No changed file \(path)", sourceLocation: sourceLocation)
    }

    /// Renders `view` in the window's environment.
    func render(_ view: some View, size: CGSize, appearance: SnapshotAppearance = .light) -> NSBitmapImageRep {
        // The diff builds its rows off the main actor; a snapshot needs
        // them now.
        Snapshot.render(view.environment(\.diffBuildsSynchronously, true).windowEnvironment(context), size: size, appearance: appearance)
    }
}

/// A repository with one commit on `main` (README.md), pushed to a bare
/// `origin`, then changes: a modified README, a new file in a folder, and
/// a deleted one.
func setupRepositoryWithChanges() async throws -> (local: Repository, remote: Repository) {
    let (local, remote) = try await setupRepositoryWithRemote()
    try Data("# Espalier\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "LICENSE")))
    try await runGit(["add", "LICENSE"], local)
    try await runGit(["commit", "-m", "Add a license"], local)
    try await runGit(["push", "origin", "HEAD"], local)
    try Data("# Readme\n\nChanged.\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
    try FileManager.default.createDirectory(atPath: POSIXPath.join(local.path, "Sources/App"), withIntermediateDirectories: true)
    try Data("struct Loader {}\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "Sources/App/Loader.swift")))
    try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, "LICENSE"))
    return (local, remote)
}

/// Fixed values for the Changes place's snapshots.
@MainActor
enum ChangesFixtures {
    static let author = AuthorIdentityContent(name: "Joe Bloggs", email: "joe@example.com")

    /// A GitHub.com account (no token: nothing reaches GitHub).
    static let account = Account(
        login: "joe",
        endpoint: getDotComAPIEndpoint(),
        token: "",
        emails: [APIEmail(email: "joe@example.com", verified: true, primary: true, visibility: .public)],
        avatarURL: "",
        id: 1234,
        name: "Joe Bloggs"
    )

    /// `octo-org/website` on GitHub.com.
    static func website(_ permissions: GitHubRepositoryPermission = .write) -> GitHubRepository {
        ModelFixtures.gitHubRepository(owner: "octo-org", name: "website", permissions: permissions)
    }

    /// The rulesets of `octo-org/website`'s main branch.
    static let mainRulesets = URL(string: "https://github.com/octo-org/website/rules/?ref=refs%2Fheads%2Fmain")!

    static func button(files: Int = 2, branch: String? = "main", enabled: Bool = true) -> CommitButtonContent {
        CommitButtonContent(fileCount: files, branch: branch, isEnabled: enabled, disabledReason: enabled ? nil : "Enter a summary to commit")
    }

    /// The composer with `draft`'s text, in a column-sized frame.
    static func composer(_ content: ComposerContent, draft: CommitDraft = CommitDraft()) -> some View {
        ComposerView(content, draft: .constant(draft))
            .frame(width: Metrics.Column.changesFileList.ideal)
    }
}

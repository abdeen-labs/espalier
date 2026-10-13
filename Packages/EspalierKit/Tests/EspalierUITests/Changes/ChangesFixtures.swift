// Fixtures for the Changes place's tests: repositories with changes and a
// window context.

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

    /// Adds `local` to a new app, selects it, and makes a window showing
    /// Changes.
    static func make(_ local: Repository) async throws -> ChangesWindowFixture {
        let harness = try AppHarness()
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

    /// The changed file at `path`.
    func file(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> WorkingDirectoryFileChange {
        try #require(repository.changes.workingDirectory.files.first { $0.path == path }, "No changed file \(path)", sourceLocation: sourceLocation)
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

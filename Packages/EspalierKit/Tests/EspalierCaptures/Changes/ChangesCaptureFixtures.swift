// Fixtures for the Changes captures: a repository with changes, selected in
// an app with a window showing Changes; the composer's fixed values; and
// capturing a view hosted in a window that stays up while what the view
// loads once it shows arrives (a diff's rows build off the main actor).

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

/// A loaded app with one selected repository and a window showing Changes.
@MainActor
struct ChangesCaptureRepository {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    /// The repository on disk.
    let local: Repository

    /// Adds `local` to a new app, selects it, and makes a window showing
    /// Changes.
    static func make(_ local: Repository) async throws -> ChangesCaptureRepository {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        await app.accounts.idle()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        context.state.select(.changes, in: repository.id)
        let fixture = ChangesCaptureRepository(harness: harness, app: app, repository: repository, context: context, local: local)
        await fixture.settle()
        return fixture
    }

    /// A repository with one commit on `main` (README.md) and a second
    /// (LICENSE), pushed to a bare `origin`, then changes: a modified
    /// README, a new file in a folder, and LICENSE deleted.
    static func withChanges() async throws -> Repository {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("# Espalier\n".utf8).write(to: URL(exactFilePath: POSIXPath.join(local.path, "LICENSE")))
        try await runGit(["add", "LICENSE"], local)
        try await runGit(["commit", "-m", "Add a license"], local)
        try await runGit(["push", "origin", "HEAD"], local)
        try Data("# Readme\n\nChanged.\n".utf8).write(to: URL(exactFilePath: POSIXPath.join(local.path, "README.md")))
        try FileManager.default.createDirectory(atPath: POSIXPath.join(local.path, "Sources/App"), withIntermediateDirectories: true)
        try Data("struct Loader {}\n".utf8).write(to: URL(exactFilePath: POSIXPath.join(local.path, "Sources/App/Loader.swift")))
        try FileManager.default.removeItem(atPath: POSIXPath.join(local.path, "LICENSE"))
        return local
    }

    /// Waits for refreshes, operations, and the loads that follow them.
    func settle() async {
        await app.idle()
        await repository.changes.diffIdle()
        await repository.commit.mostRecentLocalCommitIdle()
        await repository.stash.loadsIdle()
        await app.idle()
    }

    /// The changed file at `path`.
    func file(_ path: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> WorkingDirectoryFileChange {
        try #require(repository.changes.workingDirectory.files.first { $0.path == path }, "No changed file \(path)", sourceLocation: sourceLocation)
    }
}

/// Fixed values for the composer's captures.
@MainActor
enum ComposerCaptureValues {
    static let author = AuthorIdentityContent(name: "Joe Bloggs", email: "joe@example.com")

    /// The rulesets of `octo-org/website`'s main branch.
    static let mainRulesets = URL(string: "https://github.com/octo-org/website/rules/?ref=refs%2Fheads%2Fmain")!

    static func button(files: Int = 2, branch: String? = "main", enabled: Bool = true) -> CommitButtonContent {
        CommitButtonContent(fileCount: files, branch: branch, isEnabled: enabled, disabledReason: enabled ? nil : "Enter a summary to commit")
    }

    /// The composer with `draft`'s text, in a column-sized frame.
    static func composer(_ content: ComposerContent, draft: CommitDraft = CommitDraft()) -> some View {
        ComposerView(content, draft: .constant(draft), actions: ComposerActions())
            .frame(width: Metrics.Column.changesFileList.ideal)
    }
}

// MARK: - Capturing what loads once it shows

/// Captures of views hosted in a capture window that stays up while what
/// they load once they show arrives.
@MainActor
enum LoadedCapture {
    /// Captures `view` in each appearance, at `size`, else at its fitting
    /// size once it has loaded, hosted in a capture window that stays up
    /// while `loaded` waits for what the view loads once it shows; the host
    /// is laid out again before it's drawn.
    static func capture(
        _ view: some View,
        named name: String,
        area: String,
        size: CGSize? = nil,
        appearances: [CaptureAppearance] = CaptureAppearance.allCases,
        loaded: (NSView) async -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let look = Capture.look
        for appearance in appearances {
            let root = Capture.prepared(view)
                .background(Color(nsColor: Palette.background))
            let host = NSHostingView(rootView: root)
            let window = CaptureWindow(
                contentRect: CGRect(origin: .zero, size: size ?? CGSize(width: 400, height: 300)),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance.appearance
            window.contentView = host
            fit(host, in: window, size: size)
            await loaded(host)
            fit(host, in: window, size: size)
            let image = Look.with(look) {
                Capture.image(of: host)
            }
            window.contentView = nil
            Capture.write(image, named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
        }
    }

    /// Lays `host` out at `size`, else at its fitting size.
    private static func fit(_ host: NSView, in window: NSWindow, size: CGSize?) {
        host.layoutSubtreeIfNeeded()
        let fitting = size ?? host.fittingSize
        let bounds = CGRect(origin: .zero, size: CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        window.setContentSize(bounds.size)
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
    }

    /// Waits until every diff table under `view` shows the document for
    /// its content.
    static func diffDocumentShown(in view: NSView) async {
        await waitUntilRunLoopIdle {
            diffsShowTheirDocuments(in: view)
        }
    }
}

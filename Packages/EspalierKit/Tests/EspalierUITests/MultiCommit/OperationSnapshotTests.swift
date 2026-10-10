// The operations' sheets, the conflicted files' rows, the operation panel,
// and the AI conflict sheet, one image per layout: the conflicts, the
// running panel, and the AI sheet's results in light and dark, the rest in
// light. The states that differ only in words or a disabled control are
// OperationContentTests'. Leaf views take values; the Integrate and
// Cherry-pick sheets and the AI gate popover use a repository with a remote.

import AIKit
import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Operation snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct OperationSnapshotTests {
    private let area = "MultiCommit"
    /// The Changes column's ideal width, where the conflicts and the panel
    /// show.
    private let changesWidth = Metrics.Column.changesFileList.ideal
    /// The Changes place's width beside the sidebar, where the operation's
    /// bar shows.
    private let placeWidth = Metrics.Window.defaultWidth - Metrics.Column.sidebar.ideal
    /// The Integrate sheet's content width.
    private let sheetContentWidth = Metrics.Sheet.standardWidth - 2 * (Metrics.insetLarge + Metrics.grid)
    /// The AI conflict sheet's ideal size.
    private let aiSheetSize = CGSize(width: 820, height: 620)

    // MARK: Integrate

    @Test("the Integrate sheet's status lines: merging and rebasing, each outcome")
    func integrateStatus() {
        let ahead = [CommitOneLine(sha: "a", summary: "One"), CommitOneLine(sha: "b", summary: "Two")]
        let behind = [CommitOneLine(sha: "c", summary: "Three"), CommitOneLine(sha: "d", summary: "Four"), CommitOneLine(sha: "e", summary: "Five")]
        let statuses: [IntegrateStatus] = [
            .merge(current: "main", branch: "feature/login", preview: nil),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .clean, commitCount: 3)),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .clean, commitCount: 0)),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .conflicts(conflictedFiles: 2), commitCount: 3)),
            .merge(current: "main", branch: "unrelated", preview: MergePreview(status: .invalid, commitCount: 0)),
            .rebase(current: "feature/login", base: "main", preview: .loading),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: ahead, commitsBehind: behind)),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: [], commitsBehind: behind)),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: ahead, commitsBehind: [])),
            .rebase(current: "feature/login", base: "main", preview: .conflicts),
            .rebase(current: "feature/login", base: "unrelated", preview: .invalid),
        ]
        let view = VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                IntegrateStatusLine(status: status)
                Divider()
            }
        }
        .padding(Metrics.insetLarge)
        .frame(width: sheetContentWidth + 2 * Metrics.insetLarge)
        assertSnapshot(view, named: "integrate-status", area: area, appearances: [.light])
    }

    @Test("the split button: each method, ready to start, and not (the menu still switches the method)")
    func integrateButton() {
        let view = VStack(alignment: .trailing, spacing: Metrics.insetMedium) {
            ForEach(IntegrateMethod.allCases) { method in
                HStack(spacing: Metrics.insetMedium) {
                    IntegrateMethodButton(method: .constant(method), canStart: true, help: nil, start: {})
                    IntegrateMethodButton(method: .constant(method), canStart: false, help: nil, start: {})
                }
            }
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "integrate-button", area: area, appearances: [.light])
    }

    /// A repository on `main` with two other branches.
    private func branchesFixture() async throws -> OperationsFixture {
        try await makeOperationsFixture { local in
            try await runGit(["checkout", "-q", "-b", "feature/login"], local)
            try await commitFile(local, "login.txt", "login\n")
            try await runGit(["checkout", "-q", "-b", "fix/crash", "main"], local)
            try await commitFile(local, "crash.txt", "crash\n")
            try await runGit(["checkout", "-q", "main"], local)
        }
    }

    @Test("the Integrate sheet: merging (checking)")
    func integrateSheet() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await branchesFixture()
            let feature = try fixture.branch("feature/login")
            assertSnapshot(
                IntegrateBranchSheet(repository: fixture.repository, method: .merge, initialBranch: feature, onStart: { _, _ in })
                    .windowEnvironment(fixture.context),
                named: "integrate-merge", area: area, appearances: [.light]
            )
        }
    }

    // MARK: Cherry-pick and squash

    @Test("the cherry-pick target sheet")
    func cherryPickTarget() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await branchesFixture()
            assertSnapshot(
                CherryPickTargetSheet(
                    repository: fixture.repository,
                    content: CherryPickTargetContent(commitCount: 2, currentBranch: "main", commitsAreOnCurrentBranch: true),
                    onCherryPick: { _ in },
                    onCreateBranch: { _ in }
                )
                .windowEnvironment(fixture.context),
                named: "cherryPick", area: area, appearances: [.light]
            )
        }
    }

    @Test("the squash sheet: with a description and co-authors")
    func squash() {
        let coAuthors = [
            KnownAuthor(name: "Jane Doe", email: "jane@example.com", username: nil),
            KnownAuthor(name: "Sam Smith", email: "12345+sam@users.noreply.github.com", username: "sam"),
        ]
        let full = SquashSheetContent(
            commitCount: 3,
            summary: "Add the onboarding flow",
            description: "Add the welcome screen\n\nAsk for notifications after the first commit\n\nFix the welcome screen's layout in dark mode",
            coAuthors: coAuthors
        )
        assertSnapshot(SquashSheet(full, onSquash: { _ in }), named: "squash", area: area, appearances: [.light])
    }

    // MARK: Conflicts

    /// A row for each state: markers (several, one), a manual conflict, a
    /// file deleted on one side, a stash restore's (no sides), resolved,
    /// and resolved by picking a side.
    private static let conflictRows: [ConflictFileRowContent] = [
        ConflictFileRowContent(
            path: "Sources/App/RepositoryLoader.swift", state: .markers(conflicts: 3), status: "3 conflicts",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login"
        ),
        ConflictFileRowContent(
            path: "README.md", state: .markers(conflicts: 1), status: "1 conflict",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login"
        ),
        ConflictFileRowContent(
            path: "Assets/logo.png", state: .manual, status: "Manual conflict",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login"
        ),
        ConflictFileRowContent(
            path: "Sources/Legacy/Loader.swift", state: .manual, status: "File does not exist on feature/login.",
            oursLabel: "Use the modified file from main", theirsLabel: "Do not include this file from feature/login"
        ),
        ConflictFileRowContent(path: "Package.resolved", state: .manual, status: "Manual conflict"),
        ConflictFileRowContent(path: "Sources/App/EmptyState.swift", state: .resolved(isUndoable: false), status: "No conflicts remaining"),
        ConflictFileRowContent(path: "Assets/icon.png", state: .resolved(isUndoable: true), status: "Using the modified file from main"),
    ]

    @Test("conflicted files in the Changes table: every row state")
    func conflictedFiles() {
        let actions = ConflictFileRowActions(editorName: "Visual Studio Code", isEditorAvailable: true)
        let files = Self.conflictRows.map { conflictedFile($0.path) }
        let rows = Dictionary(uniqueKeysWithValues: Self.conflictRows.map { (ExactString($0.path), $0) })
        let table = FileTable(
            files: .changes(files),
            selectedIDs: [],
            inclusion: { _ in FileInclusionState(value: true, isEnabled: true, help: nil) },
            conflicts: rows,
            conflictActions: { _ in actions }
        )
        assertSnapshot(table, named: "conflicts", area: area, size: CGSize(width: changesWidth, height: 240))
    }

    // MARK: The operation panel

    @Test("the operation panel: running, conflicts stopped at a commit and resolved, AI's error, and interrupted")
    func panel() {
        let panels: [(name: String, content: OperationPanelContent, aiError: String?, appearances: [SnapshotAppearance])] = [
            ("running", OperationPanelContent(
                title: "Rebase in progress",
                state: .running(detail: "Commit 2 of 5 · Fix crash when opening an empty repository", progress: 0.4)
            ), nil, SnapshotAppearance.allCases),
            ("conflicts", .conflicts(
                operation: "Rebase", isMerge: false, resolved: 1, total: 3, unresolved: 2, isContinuing: false,
                hasUntrackedFiles: true, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true,
                step: OperationStep(position: 2, total: 4)
            ), nil, SnapshotAppearance.allCases),
            ("conflicts-resolved", .conflicts(
                operation: "Rebase", isMerge: false, resolved: 3, total: 3, unresolved: 0, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true,
                step: OperationStep(position: 2, total: 4)
            ), nil, [.light]),
            ("conflicts-aiError", .conflicts(
                operation: "Merge", isMerge: true, resolved: 0, total: 2, unresolved: 2, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: true, canResolveWithAI: true
            ), "The provider rejected the API key. Check it in Settings ▸ AI.", [.light]),
            // A stash restore's conflicts and an operation Espalier can't
            // finish (applying patches, a bisect) draw the same panel with
            // other words and buttons.
            ("interrupted", OperationPanelContent(
                title: "Rebase interrupted",
                state: .interrupted(message: "Rebasing feature/login was interrupted. Continue or abort the rebase."),
                abortTitle: "Abort Rebase",
                continueTitle: "Continue Rebase",
                canContinue: true
            ), nil, [.light]),
        ]
        for panel in panels {
            assertSnapshot(
                OperationPanelView(content: panel.content, aiError: panel.aiError).frame(width: placeWidth),
                named: "panel-\(panel.name)", area: area, appearances: panel.appearances
            )
        }
    }

    // MARK: The AI conflict sheet

    @Test("the AI sheet while it works: the model's reasoning")
    func aiLoading() {
        let reasoning = AIConflictLoadingContent(
            title: "Resolving conflicts for rebase",
            modelLabel: "GPT-5 · High",
            phase: "Analyzing conflicts…",
            progress: "2 of 5 files",
            reasoning: [
                "Comparing how each side changed the loader's error handling.",
                "main added a retry after a failed load; feature/login added an empty-state path.",
                "Both can be kept: the retry wraps the new empty-state path.",
            ],
            fallbackLines: [],
            abortTitle: "Abort Rebase"
        )
        assertSnapshot(
            AIConflictLoadingView(content: reasoning).frame(width: aiSheetSize.width, height: aiSheetSize.height),
            named: "ai-loading",
            area: area,
            appearances: [.light]
        )
    }

    private static let summary = AIConflictSummaryContent(
        operationPhrase: "Rebasing feature/login onto main",
        markdown: "Both branches changed **RepositoryLoader**. The resolution keeps main's retry after a failed load and the branch's empty-state path, which the retry now wraps.",
        references: [
            AIConflictReference(
                id: "pr-0", kind: .pullRequest(number: 142), title: "Show an empty history for new repositories",
                url: URL(string: "https://github.com/octo-org/website/pull/142")
            ),
            AIConflictReference(
                id: "commit-1", kind: .commit(shortSHA: "a1b2c3d", isOnRemote: true), title: "Retry loading after a failure",
                url: URL(string: "https://github.com/octo-org/website/commit/a1b2c3d")
            ),
            AIConflictReference(id: "commit-2", kind: .commit(shortSHA: "e4f5a6b", isOnRemote: false), title: "Tidy the loader"),
        ]
    )

    private static func options(model: Bool, checked: ConflictResolutionChoice) -> [AIResolutionRow.Option] {
        var options: [AIResolutionRow.Option] = []
        if model {
            options.append(.init(title: "Use the model's suggestion", choice: .model, isChecked: checked == .model))
        }
        options.append(.init(title: "Use current file from main", choice: .ours, isChecked: checked == .ours))
        options.append(.init(title: "Use incoming file from feature/login", choice: .theirs, isChecked: checked == .theirs))
        return options
    }

    private static func results(
        skipped: Bool = true,
        failed: Bool = true,
        canContinue: Bool = false,
        error: String? = nil
    ) -> AIConflictResultsContent {
        AIConflictResultsContent(
            title: "Resolve conflicts before Rebase",
            modelLabel: "GPT-5 · High",
            summary: summary,
            conflicted: [
                AIResolutionRow(
                    path: "Sources/App/RepositoryLoader.swift",
                    explanation: "Kept main's retry and wrapped the branch's empty-state path in it.",
                    choiceLabel: "The Model",
                    options: options(model: true, checked: .model),
                    isResolved: false
                ),
                AIResolutionRow(
                    path: "Sources/App/EmptyState.swift",
                    explanation: "Using changes from main",
                    choiceLabel: "Current",
                    options: options(model: true, checked: .ours),
                    isResolved: false
                ),
                AIResolutionRow(path: "README.md", explanation: "No conflicts remaining", choiceLabel: "", options: [], isResolved: true),
            ],
            skipped: skipped ? [
                AIResolutionRow(
                    path: "Assets/logo.png",
                    explanation: "Binary files can't be resolved by the model.",
                    choiceLabel: "Choose a resolution",
                    options: options(model: false, checked: .model),
                    isResolved: false
                ),
            ] : [],
            failed: failed ? [
                AIResolutionRow(
                    path: "Sources/Legacy/Loader.swift",
                    explanation: "The request timed out.",
                    choiceLabel: "Choose a resolution",
                    options: options(model: false, checked: .model),
                    isResolved: false
                ),
            ] : [],
            retryProgress: nil,
            abortTitle: "Abort Rebase",
            continueTitle: "Continue Rebase",
            canContinue: canContinue,
            continueHelp: canContinue ? nil : AIConflictResultsContent.skippedHelp,
            isContinuing: false,
            error: error
        )
    }

    @Test("the AI sheet's results: skipped and failed files; all resolved, with an error")
    func aiResults() throws {
        let harness = try AppHarness()
        let context = WindowContext(app: harness.makeApp())
        func view(_ content: AIConflictResultsContent) -> some View {
            AIConflictResultsView(content: content, alwaysUseAI: .constant(false))
                .frame(width: aiSheetSize.width, height: aiSheetSize.height)
                .windowEnvironment(context)
        }
        assertSnapshot(view(Self.results()), named: "ai-results", area: area)
        assertSnapshot(
            view(Self.results(skipped: false, failed: false, canContinue: true, error: "Couldn't write Sources/App/RepositoryLoader.swift: the file is locked.")),
            named: "ai-results-resolved", area: area, appearances: [.light]
        )
    }

    @Test("the AI sheet's failure, fixed in Settings")
    func aiFailure() {
        let settings = AIConflictFailureContent(
            title: "Resolve conflicts before Rebase",
            modelLabel: "GPT-5 · High",
            message: "The provider rejected the API key. Check it in Settings ▸ AI.",
            opensSettings: true,
            abortTitle: "Abort Rebase"
        )
        assertSnapshot(
            AIConflictFailureView(content: settings, alwaysUseAI: .constant(true)).frame(width: aiSheetSize.width, height: 300),
            named: "ai-failure-settings", area: area, appearances: [.light]
        )
    }

    @Test("the AI consent sheet, for a provider elsewhere")
    func aiConsent() {
        let remote = getAIDataDisclosure(for: .conflictResolution, provider: SettingsFixtures.remoteProvider)
        assertSnapshot(AIConsentSheet(disclosure: remote, onContinue: {}), named: "ai-consent", area: area, appearances: [.light])
    }

    @Test("Resolve with AI's popover: choose a model")
    func aiGate() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeOperationsFixture()
            let repository = fixture.repository
            try fixture.app.ai.addProvider(SettingsFixtures.localProvider)
            try fixture.app.ai.addProvider(SettingsFixtures.remoteProvider)
            assertSnapshot(
                AIGatePopover(gate: .chooseModel(repository.id), repository: repository).windowEnvironment(fixture.context),
                named: "ai-gate-chooseModel", area: area, appearances: [.light]
            )
        }
    }
}

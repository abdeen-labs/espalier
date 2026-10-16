// The operations' sheets, the conflicted files' rows, the band above a
// conflicted file's diff, the operation panel, and the AI conflict sheet,
// one capture per layout. Leaf views take
// values; the Integrate and Cherry-pick sheets and the AI gate popover use
// a repository with a remote, the AI sheet's Changes tab a merge's
// conflict.

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

@Suite("MultiCommit", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct MultiCommitCaptures {
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
            .merge(current: "main", branch: "feature/login", preview: nil, numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .clean, commitCount: 3), numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .clean, commitCount: 0), numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .conflicts(conflictedFiles: 2), commitCount: 3), numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: .conflicts(conflictedFiles: 2), commitCount: nil), numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "unrelated", preview: MergePreview(status: .invalid, commitCount: 0), numberFormat: Capture.numberFormat),
            .merge(current: "main", branch: "feature/login", preview: MergePreview(status: nil, commitCount: 3), numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "main", preview: .loading, numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: ahead, commitsBehind: behind), numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: [], commitsBehind: behind), numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "main", preview: .clean(commitsAhead: ahead, commitsBehind: []), numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "main", preview: .conflicts, numberFormat: Capture.numberFormat),
            .rebase(current: "feature/login", base: "unrelated", preview: .invalid, numberFormat: Capture.numberFormat),
        ]
        let view = VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                IntegrateStatusLine(status: status)
                Divider()
            }
        }
        .padding(Metrics.insetLarge)
        .frame(width: sheetContentWidth + 2 * Metrics.insetLarge)
        capture(view, named: "integrate-status", area: area)
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
        capture(view, named: "integrate-button", area: area)
    }

    /// A repository on `main` with two other branches, their tips' dates
    /// loaded (the sheets' pickers load them as they show; loaded first,
    /// they come from the cache).
    private func branchesFixture() async throws -> OperationsCaptureRepository {
        let fixture = try await OperationsCaptureRepository.make { local in
            try await runGit(["checkout", "-q", "-b", "feature/login"], local)
            try await OperationsCaptureRepository.commitFile(local, "login.txt", "login\n")
            try await runGit(["checkout", "-q", "-b", "fix/crash", "main"], local)
            try await OperationsCaptureRepository.commitFile(local, "crash.txt", "crash\n")
            try await runGit(["checkout", "-q", "main"], local)
        }
        _ = await fixture.repository.branches.tipDates(for: fixture.repository.gitState.branches.all)
        return fixture
    }

    @Test("the Integrate sheet: merging, while it checks whether Git can merge automatically")
    func integrateSheet() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await branchesFixture()
            let feature = try fixture.branch("feature/login")
            let sheet = IntegrateBranchSheet(repository: fixture.repository, method: .merge, initialBranch: feature, onStart: { _, _ in })
                .windowEnvironment(fixture.context)
            // Drawn as it opens: the preview is the sheet's own load, which
            // nothing outside it can wait for.
            capture(sheet, named: "integrate-merge", area: area)
            await fixture.settle()
        }
    }

    // MARK: Cherry-pick and squash

    @Test("the cherry-pick target sheet")
    func cherryPickTarget() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await branchesFixture()
            let sheet = CherryPickTargetSheet(
                repository: fixture.repository,
                content: CherryPickTargetContent(commitCount: 2, currentBranch: "main", commitsAreOnCurrentBranch: true),
                onCherryPick: { _ in },
                onCreateBranch: { _ in }
            )
            .windowEnvironment(fixture.context)
            await LoadedCapture.capture(sheet, named: "cherryPick", area: area) { _ in
                await fixture.settle()
            }
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
        capture(SquashSheet(full, onSquash: { _ in }), named: "squash", area: area)
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

    /// A file conflicted with markers in it.
    private static func conflictedFile(_ path: String) -> WorkingDirectoryFileChange {
        let status = ConflictedFileStatus.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3, conflictCount: 1)
        return WorkingDirectoryFileChange(path: path, status: .conflicted(status), selection: DiffSelection.fromInitialSelection(.all))
    }

    @Test("conflicted files in the Changes table: every row state")
    func conflictedFiles() {
        let actions = ConflictFileRowActions(editorName: "Visual Studio Code", isEditorAvailable: true)
        let files = Self.conflictRows.map { Self.conflictedFile($0.path) }
        let rows = Dictionary(uniqueKeysWithValues: Self.conflictRows.map { (ExactString($0.path), $0) })
        let table = FileTable(
            files: .changes(files),
            selectedIDs: [],
            inclusion: { _ in FileInclusionState(value: true, isEnabled: true, help: nil) },
            conflicts: rows,
            conflictActions: { _ in actions }
        )
        capture(table, named: "conflicts", area: area, size: CGSize(width: changesWidth, height: 240))
    }

    // MARK: The band above a conflicted file's diff

    /// The band's states: a merge's markers, with an editor and without, a
    /// rebase's whose base isn't a branch, a binary file, a file deleted on
    /// one side, a stash restore's (no sides), a side chosen, and resolved.
    private static let bandRows: [(name: String, row: ConflictFileRowContent, hasEditor: Bool)] = [
        ("markers", ConflictFileRowContent(
            path: "Sources/App/RepositoryLoader.swift", state: .markers(conflicts: 3), status: "3 conflicts",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login",
            oursVersionTitle: "Use main's Version", theirsVersionTitle: "Use feature/login's Version"
        ), true),
        ("markers-noEditor", ConflictFileRowContent(
            path: "Sources/App/RepositoryLoader.swift", state: .markers(conflicts: 1), status: "1 conflict",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login",
            oursVersionTitle: "Use main's Version", theirsVersionTitle: "Use feature/login's Version"
        ), false),
        ("markers-unnamed", ConflictFileRowContent(
            path: "Sources/App/RepositoryLoader.swift", state: .markers(conflicts: 2), status: "2 conflicts",
            oursLabel: "Use the modified file", theirsLabel: "Use the modified file from feature/login",
            oursVersionTitle: "Use Current Version", theirsVersionTitle: "Use feature/login's Version"
        ), true),
        ("binary", ConflictFileRowContent(
            path: "Assets/logo.png", state: .manual, status: "Manual conflict",
            oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature/login",
            oursVersionTitle: "Use main's Version", theirsVersionTitle: "Use feature/login's Version"
        ), true),
        ("deleted", ConflictFileRowContent(
            path: "Sources/Legacy/Loader.swift", state: .manual, status: "File does not exist on feature/login.",
            oursLabel: "Use the modified file from main", theirsLabel: "Do not include this file on feature/login",
            oursVersionTitle: "Use main's Version", theirsVersionTitle: "Use feature/login's Version"
        ), true),
        ("restore", ConflictFileRowContent(path: "README.md", state: .markers(conflicts: 1), status: "1 conflict"), true),
        ("chosen", ConflictFileRowContent(path: "Assets/icon.png", state: .resolved(isUndoable: true), status: "Using the modified file from main"), true),
        ("resolved", ConflictFileRowContent(path: "README.md", state: .resolved(isUndoable: false), status: "No conflicts remaining"), true),
    ]

    @Test("the band above a conflicted file's diff: each state, at the diff's default width and its narrowest")
    func band() {
        for band in Self.bandRows {
            let actions = ConflictFileRowActions(editorName: "Visual Studio Code", isEditorAvailable: band.hasEditor)
            for (suffix, width) in [("", CGFloat(640)), ("-narrow", Metrics.Column.diffMinimum)] {
                capture(
                    ConflictBand(content: band.row, actions: actions).frame(width: width),
                    named: "band-\(band.name)\(suffix)", area: area
                )
            }
        }
    }

    // MARK: The operation panel

    @Test("the operation panel: running, a rebase's conflicts stopped at a commit and resolved, a merge's, no conflicted files, AI's error, a stash restore's, and interrupted")
    func panel() {
        let panels: [(name: String, content: OperationPanelContent, aiError: String?)] = [
            ("running", OperationPanelContent(
                title: "Rebase in progress",
                state: .running(detail: "Commit 2 of 5 · Fix crash when opening an empty repository", progress: 0.4)
            ), nil),
            ("conflicts", .conflicts(
                operation: "Rebase", isMerge: false, resolved: 1, total: 3, unresolved: 2, isContinuing: false,
                hasUntrackedFiles: true, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true,
                step: OperationStep(position: 2, total: 4), numberFormat: Capture.numberFormat
            ), nil),
            ("conflicts-resolved", .conflicts(
                operation: "Rebase", isMerge: false, resolved: 3, total: 3, unresolved: 0, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: true, showsResolveWithAI: true, canResolveWithAI: true,
                step: OperationStep(position: 2, total: 4), numberFormat: Capture.numberFormat
            ), nil),
            ("conflicts-none", .conflicts(
                operation: "Merge", isMerge: true, resolved: 0, total: 0, unresolved: 0, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: true, canResolveWithAI: true,
                numberFormat: Capture.numberFormat
            ), nil),
            ("conflicts-merge", .conflicts(
                operation: "Merge", isMerge: true, resolved: 0, total: 2, unresolved: 2, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: false, canResolveWithAI: false,
                numberFormat: Capture.numberFormat
            ), nil),
            ("conflicts-aiError", .conflicts(
                operation: "Merge", isMerge: true, resolved: 0, total: 2, unresolved: 2, isContinuing: false,
                hasUntrackedFiles: false, isRebaseFamily: false, showsResolveWithAI: true, canResolveWithAI: true,
                numberFormat: Capture.numberFormat
            ), "The provider rejected the API key. Check it in Settings ▸ AI."),
            ("stashConflicts", OperationPanelContent(
                title: "Resolve conflicts",
                state: .stashConflicts(message: "Restoring the stash on main caused conflicts. Resolve them to finish; the stash is kept until you do."),
                howTo: OperationPanelContent.howToResolveStash
            ), nil),
            // A stash restore's conflicts and an operation Espalier can't
            // finish (applying patches, a bisect) draw the same panel with
            // other words and buttons.
            ("interrupted", OperationPanelContent(
                title: "Rebase interrupted",
                state: .interrupted(message: "Rebasing feature/login was interrupted. Continue or abort the rebase."),
                abortTitle: "Abort Rebase",
                continueTitle: "Continue Rebase",
                canContinue: true
            ), nil),
        ]
        for panel in panels {
            capture(
                OperationPanelView(content: panel.content, aiError: panel.aiError).frame(width: placeWidth),
                named: "panel-\(panel.name)", area: area
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
        capture(
            AIConflictLoadingView(content: reasoning).frame(width: aiSheetSize.width, height: aiSheetSize.height),
            named: "ai-loading",
            area: area
        )
    }

    private static let loaderSummary = """
        ### Conflicting changes
        Both branches changed **RepositoryLoader**: a1b2c3d added a retry after a failed load, and #142 an empty-state path.

        ### Resolution
        Kept both: the retry now wraps the branch's empty-state path.
        """

    private static let summary = AIConflictSummaryContent(
        operationPhrase: "Rebasing feature/login onto main",
        sections: [.init(id: 0, markdown: loaderSummary)],
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

    /// Two requests' summaries, each under the files it covers.
    private static var batchSummary: AIConflictSummaryContent {
        var batches = summary
        batches.sections = [
            .init(id: 0, paths: ["Sources/App/RepositoryLoader.swift", "Sources/App/EmptyState.swift", "README.md"], markdown: loaderSummary),
            .init(
                id: 1,
                paths: ["Sources/Cache/Store.swift", "Sources/Cache/Eviction.swift"],
                markdown: """
                    ### Conflicting changes
                    main moved eviction into **Store**, and feature/login capped the old eviction path's size.

                    ### Resolution
                    Moved the cap into Store's eviction; **the old path's cap was dropped**.
                    """
            ),
        ]
        return batches
    }

    private static func results(
        skipped: Bool = true,
        failed: Bool = true,
        batches: Bool = false,
        retryProgress: String? = nil,
        canContinue: Bool = false,
        error: String? = nil
    ) -> AIConflictResultsContent {
        AIConflictResultsContent(
            title: "Resolve conflicts before Rebase",
            modelLabel: "GPT-5 · High",
            summary: batches ? batchSummary : summary,
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
            ] + (batches ? [
                AIResolutionRow(
                    path: "Sources/Cache/Store.swift",
                    explanation: "Moved the branch's size cap into Store's eviction.",
                    choiceLabel: "The Model",
                    options: options(model: true, checked: .model),
                    isResolved: false
                ),
                AIResolutionRow(
                    path: "Sources/Cache/Eviction.swift",
                    explanation: "Kept main's removal of the old eviction path.",
                    choiceLabel: "The Model",
                    options: options(model: true, checked: .model),
                    isResolved: false
                ),
            ] : []),
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
            retryProgress: retryProgress,
            abortTitle: "Abort Rebase",
            continueTitle: "Continue Rebase",
            canContinue: canContinue,
            continueHelp: canContinue ? nil : AIConflictResultsContent.continueHelp(skipped: skipped, failed: failed),
            isContinuing: false,
            error: error
        )
    }

    @Test("the AI sheet's results: skipped and failed files; retrying them; all resolved, with an error; several requests' summaries")
    func aiResults() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await OperationsCaptureRepository.make()
            @MainActor func view(_ content: AIConflictResultsContent) -> some View {
                AIConflictResultsView(content: content, repository: fixture.repository, alwaysUseAI: .constant(false))
                    .frame(width: aiSheetSize.width, height: aiSheetSize.height)
                    .windowEnvironment(fixture.context)
            }
            capture(view(Self.results()), named: "ai-results", area: area)
            capture(view(Self.results(retryProgress: "Retrying 1 file…")), named: "ai-results-retrying", area: area)
            capture(
                view(Self.results(skipped: false, failed: false, canContinue: true, error: "Couldn't write Sources/App/RepositoryLoader.swift: the file is locked.")),
                named: "ai-results-resolved", area: area
            )
            capture(
                view(Self.results(skipped: false, failed: false, batches: true, canContinue: true)),
                named: "ai-results-batches", area: area
            )
            await fixture.settle()
        }
    }

    @Test("the AI sheet's results for a rebase whose base branch isn't known, made from the round as the sheet makes them")
    func aiResultsRebaseUnknownBase() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await OperationsCaptureRepository.make()
            let branches = ConflictBranches(ours: nil, theirs: "feature/login")
            let roundLabels = (ours: "0123456", theirs: "feature/login")
            let markers = ConflictedFileStatus.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3, conflictCount: 1)
            func row(_ path: String, _ status: ConflictedFileStatus, _ choice: ConflictResolutionChoice) -> AIResolutionRow {
                AIConflictResultsContent.resolutionRow(
                    path: path,
                    status: status,
                    choice: choice,
                    resolution: nil,
                    branches: branches,
                    roundLabels: roundLabels,
                    offersModel: true,
                    failure: nil
                )
            }
            let summary = AIConflictSummaryContent.make(
                AIResolutionSummary(
                    summaries: [AIChunkSummary(markdown: Self.loaderSummary, paths: ["Sources/App/RepositoryLoader.swift"])],
                    ourLabel: roundLabels.ours,
                    theirLabel: roundLabels.theirs,
                    references: []
                ),
                resolvedPaths: ["Sources/App/RepositoryLoader.swift"],
                operation: .rebase,
                htmlURL: nil
            )
            let content = AIConflictResultsContent(
                title: "Resolve conflicts before Rebase",
                modelLabel: "GPT-5 · High",
                summary: summary,
                conflicted: [
                    row("Sources/App/EmptyState.swift", markers, .ours),
                    row("Sources/App/RepositoryLoader.swift", markers, .theirs),
                    row("Sources/Legacy/Loader.swift", .manualConflict(entry: ManualConflictEntry(action: .deletedByUs)), .ours),
                ],
                skipped: [],
                failed: [],
                retryProgress: nil,
                abortTitle: "Abort Rebase",
                continueTitle: "Continue Rebase",
                canContinue: true,
                continueHelp: nil,
                isContinuing: false,
                error: nil
            )
            capture(
                AIConflictResultsView(content: content, repository: fixture.repository, alwaysUseAI: .constant(false))
                    .frame(width: aiSheetSize.width, height: aiSheetSize.height)
                    .windowEnvironment(fixture.context),
                named: "ai-results-rebase-unknown-base",
                area: area
            )
            await fixture.settle()
        }
    }

    @Test("the AI sheet's Changes tab: a file's chosen side against the file with its markers")
    func aiChanges() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesCaptureRepository.make(try await setupConflictedRepo())
            fixture.repository.ai.setResolutionChoice(.ours, forPath: "foo")
            await captureDiffView(
                { AIResolutionChanges(repository: fixture.repository, paths: ["foo"]).windowEnvironment(fixture.context) },
                named: "ai-changes",
                area: area,
                size: CGSize(width: aiSheetSize.width, height: 360),
                appearances: CaptureAppearance.allCases
            )
            await fixture.app.idle()
        }
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
        capture(
            AIConflictFailureView(content: settings, alwaysUseAI: .constant(true)).frame(width: aiSheetSize.width, height: 300),
            named: "ai-failure-settings", area: area
        )
    }

    // MARK: Providers

    /// A local OpenAI-compatible server without credentials.
    private static let localProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000001",
        name: "Ollama",
        type: .openai,
        baseUrl: "http://localhost:11434/v1",
        wireApi: .completions,
        authKind: .none,
        models: [BYOKModel(id: "llama3:latest", name: "Llama 3")]
    )

    /// A remote provider with an API key and two models, one with a
    /// reasoning effort.
    private static let remoteProvider = BYOKProvider(
        id: "8f0c1d2e-0000-4000-8000-000000000002",
        name: "OpenAI",
        type: .openai,
        baseUrl: "https://api.openai.com/v1",
        wireApi: .responses,
        authKind: .apiKey,
        requestTimeoutSeconds: 120,
        models: [
            BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .high),
            BYOKModel(id: "gpt-5-mini", name: "GPT-5 mini"),
        ]
    )

    @Test("the AI consent sheet, for a provider elsewhere")
    func aiConsent() {
        let remote = getAIDataDisclosure(for: .conflictResolution, provider: Self.remoteProvider)
        capture(AIConsentSheet(disclosure: remote, onContinue: {}), named: "ai-consent", area: area)
    }

    @Test("Resolve with AI's popover: choose a model")
    func aiGate() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await OperationsCaptureRepository.make()
            let repository = fixture.repository
            try fixture.app.ai.addProvider(Self.localProvider)
            try fixture.app.ai.addProvider(Self.remoteProvider)
            capture(
                AIGatePopover(gate: .chooseModel(repository.id), repository: repository).windowEnvironment(fixture.context),
                named: "ai-gate-chooseModel", area: area
            )
            await fixture.settle()
        }
    }
}

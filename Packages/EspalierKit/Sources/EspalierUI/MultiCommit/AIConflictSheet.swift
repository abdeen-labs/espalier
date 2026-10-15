// Ported in part from desktop/app/src/ui/multi-commit-operation/dialog/copilot-conflicts-loading-dialog.tsx, copilot-conflicts-dialog.tsx, and copilot-resolution-helpers.ts
//
// The AI conflict sheet: the loading phase (its title, the model label,
// "Gathering context…" and "Analyzing conflicts…", the reasoning lines and
// their fallbacks, Stop, Abort) and the results (per-file choices and their
// labels, the skipped files, Switch to Manual, Continue's tooltip). Its
// state is `ai.conflictResolution`, which also starts rounds by itself
// ("Always use AI when conflicts are detected"): the window's host opens the
// sheet whenever a round exists and closes it when the round ends. Errors
// show in the sheet (or under Resolve with AI), never as alerts.

import AIKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import Observation
import SwiftUI

// MARK: - The flow

/// What Resolve with AI needs before it starts, shown as a popover on the
/// button.
nonisolated enum AIConflictGate: Sendable, Equatable, Identifiable {
    /// No provider: set one up in Settings ▸ AI.
    case setup(RepositoryID)
    /// Several models and none chosen for conflicts.
    case chooseModel(RepositoryID)

    var id: String {
        switch self {
        case .setup(let id): "setup-\(id.rawValue)"
        case .chooseModel(let id): "model-\(id.rawValue)"
        }
    }

    var repositoryID: RepositoryID {
        switch self {
        case .setup(let id), .chooseModel(let id): id
        }
    }
}

/// The window's AI conflict flow: the gate showing, and the errors that
/// show inline.
@MainActor @Observable
final class AIConflictFlowState {
    /// The popover Resolve with AI shows, if any.
    var gate: AIConflictGate?
    /// Why the last start failed, by repository (shown under the button).
    private var startErrors: [RepositoryID: String] = [:]
    /// Why applying the resolutions failed (shown in the sheet).
    var applyError: String?
    /// Whether the sheet's Continue is applying and continuing.
    var isContinuing = false

    func startError(for id: RepositoryID) -> String? {
        startErrors[id]
    }

    func setStartError(_ message: String?, for id: RepositoryID) {
        startErrors[id] = message
    }
}

/// Resolve with AI, its gates, and the sheet's actions.
@MainActor
enum AIConflictFlow {
    static func state(in context: WindowContext) -> AIConflictFlowState {
        context.state.featureState(AIConflictFlowState.self) { AIConflictFlowState() }
    }

    /// Resolve with AI: the gates of the sparkle (a provider, a model,
    /// consent), then a round; the host opens the sheet once it runs.
    static func start(in context: WindowContext, repository: RepositoryModel) {
        let state = state(in: context)
        state.setStartError(nil, for: repository.id)
        switch context.app.ai.status(for: .conflictResolution) {
        case .disabled:
            return
        case .needsProvider:
            state.gate = .setup(repository.id)
        case .needsModelChoice:
            state.gate = .chooseModel(repository.id)
        case .needsConsent(let disclosure):
            AIConsentSheet.present(disclosure, in: context) { [weak context] in
                guard let context else {
                    return
                }
                context.app.ai.recordConsent(disclosure.consentIdentifier)
                begin(in: context, repository: repository)
            }
        case .ready:
            begin(in: context, repository: repository)
        }
    }

    /// Starts the round. A round's failure stays in its state, which the
    /// sheet shows; a refusal before it starts shows under the button.
    static func begin(in context: WindowContext, repository: RepositoryModel) {
        let state = state(in: context)
        let presenter = context.presenter
        Task {
            do throws(OperationError) {
                _ = try await presenter.performThrowing { _ throws(OperationError) in
                    try await repository.ai.resolveConflicts()
                }
            } catch {
                if case .failed = repository.ai.conflictResolution {
                    return
                }
                state.setStartError(error.message, for: repository.id)
            }
        }
    }

    /// Continue <Op>: writes the resolutions, then continues the operation
    /// (`applyResolutions()` returns after the status refresh).
    static func applyAndContinue(in context: WindowContext, repository: RepositoryModel) {
        let state = state(in: context)
        guard !state.isContinuing else {
            return
        }
        state.isContinuing = true
        state.applyError = nil
        let presenter = context.presenter
        Task { [weak context] in
            defer {
                state.isContinuing = false
            }
            do throws(OperationError) {
                guard try await presenter.performThrowing({ _ throws(OperationError) in
                    try await repository.ai.applyResolutions()
                }) != nil else {
                    return
                }
            } catch {
                state.applyError = error.message
                return
            }
            guard let context else {
                return
            }
            await MultiCommitActions.continueOperation(in: context, repository: repository)
        }
    }

    /// Abort <Op>, asking first when conflicts were resolved.
    static func abort(in context: WindowContext, repository: RepositoryModel) {
        Task { [weak context] in
            guard let context else {
                return
            }
            await MultiCommitActions.abortOperation(in: context, repository: repository)
        }
    }

    /// Try Again: retries the failed and unattempted files.
    static func retry(in context: WindowContext, repository: RepositoryModel) {
        let state = state(in: context)
        let presenter = context.presenter
        state.applyError = nil
        Task {
            do throws(OperationError) {
                _ = try await presenter.performThrowing { _ throws(OperationError) in
                    try await repository.ai.retryFailedFiles()
                }
            } catch {
                state.applyError = error.message
            }
        }
    }
}

// MARK: - The gates

/// Resolve with AI's popover: set up a provider, or choose a model.
struct AIGatePopover: View {
    let gate: AIConflictGate
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    /// The popover's width.
    private static let width: CGFloat = 300

    init(gate: AIConflictGate, repository: RepositoryModel) {
        self.gate = gate
        self.repository = repository
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            switch gate {
            case .setup:
                Text("Resolve Conflicts with AI")
                    .font(Typography.heading)
                    .foregroundStyle(.text)
                Text("Add a provider to use your own API key with OpenAI-compatible endpoints, Azure, Anthropic, or local providers like Ollama.")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open AI Settings…") {
                    AIConflictFlow.state(in: context).gate = nil
                    context.actions.perform(.openSettings(.ai))
                }
                .buttonStyle(.prominent)
            case .chooseModel:
                Text("Choose a model")
                    .font(Typography.heading)
                VStack(spacing: 0) {
                    ForEach(context.app.ai.availableModels) { choice in
                        Button {
                            context.app.ai.select(model: choice.key, for: .conflictResolution)
                            AIConflictFlow.state(in: context).gate = nil
                            AIConflictFlow.start(in: context, repository: repository)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.model.name)
                                Text(choice.provider.name)
                                    .font(Typography.subheadline)
                                    .foregroundStyle(.text2)
                            }
                        }
                        .buttonStyle(PopoverItemButtonStyle())
                    }
                }
                // The highlight reaches into the margin; the names line up
                // with the title.
                .padding(.horizontal, -Metrics.insetSmall)
            }
        }
        .padding(Metrics.Popover.padding)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(espalier: Palette.background))
    }
}

/// An item in a popover's list: the label across the width, highlighted
/// under the pointer and while pressed.
private struct PopoverItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PopoverItem(configuration: configuration)
    }

    private struct PopoverItem: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.vertical, Metrics.grid)
                .padding(.horizontal, Metrics.insetSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                        .fill(isHovered || configuration.isPressed ? Color(espalier: Palette.hover) : Color.clear)
                        .pressMotion(configuration.isPressed)
                        .hoverMotion(isHovered)
                }
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

/// What's sent before the first request to a provider: the disclosure
/// (AIKit's), Continue to agree.
struct AIConsentSheet: View {
    static let sheetID = "espalier.aiConflictConsent"

    let disclosure: AIDataDisclosure
    let onContinue: () -> Void
    @Environment(\.dismissModal) private var dismissModal

    init(disclosure: AIDataDisclosure, onContinue: @escaping () -> Void) {
        self.disclosure = disclosure
        self.onContinue = onContinue
    }

    var body: some View {
        AIConsentScaffold("Send Conflicts to \(disclosure.providerName)?", content: AIConsentContent(disclosure)) {
            dismissModal()
        } confirm: {
            dismissModal()
            onContinue()
        }
    }

    static func present(_ disclosure: AIDataDisclosure, in context: WindowContext, onContinue: @escaping () -> Void) {
        context.modals.presentSheet(id: sheetID) {
            AIConsentSheet(disclosure: disclosure, onContinue: onContinue)
        }
    }
}

// MARK: - The host

/// Opens the AI conflict sheet whenever the window's repository has a round
/// (started by Resolve with AI, or by itself), and closes it when the round
/// ends.
struct AIConflictSheetHost: ViewModifier {
    let context: WindowContext

    func body(content: Content) -> some View {
        content
            .onChange(of: HostKey(context), initial: true) {
                update()
            }
    }

    private struct HostKey: Equatable {
        let repository: RepositoryID?
        let isActive: Bool

        @MainActor
        init(_ context: WindowContext) {
            repository = context.repository?.id
            if let state = context.repository?.ai.conflictResolution, state != .idle {
                isActive = true
            } else {
                isActive = false
            }
        }
    }

    private func update() {
        let key = HostKey(context)
        let modals = context.modals
        let isPresenting = modals.isPresentingSheet(id: AIConflictSheet.sheetID)
        guard key.isActive, let repository = context.repository else {
            if isPresenting {
                modals.dismissSheet(id: AIConflictSheet.sheetID)
            }
            return
        }
        if isPresenting {
            // Another repository's round: show this one's.
            if AIConflictSheet.presentedRepository == repository.id {
                return
            }
            modals.dismissSheet(id: AIConflictSheet.sheetID)
        }
        AIConflictSheet.present(for: repository, in: context)
    }
}

// MARK: - The sheet

/// The AI conflict sheet: the round's loading phase, its results, or its
/// failure.
public struct AIConflictSheet: View {
    static let sheetID = "espalier.aiConflicts"
    /// The repository the sheet showing is for.
    @MainActor static var presentedRepository: RepositoryID?

    private let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.numberFormat) private var numberFormat

    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    public var body: some View {
        let flow = AIConflictFlow.state(in: context)
        Group {
            switch repository.ai.conflictResolution {
            case .idle:
                Color.clear
            case .resolving(let round):
                AIConflictLoadingView(
                    content: AIConflictLoadingContent(round, operationName: operationName, numberFormat: numberFormat),
                    onStop: { repository.ai.stopResolvingConflicts() },
                    onAbort: { AIConflictFlow.abort(in: context, repository: repository) }
                )
            case .resolved(let results):
                AIConflictResultsView(
                    content: AIConflictResultsContent.make(
                        results,
                        repository: repository,
                        operationName: operationName,
                        isContinuing: flow.isContinuing,
                        error: flow.applyError,
                        numberFormat: numberFormat
                    ),
                    repository: repository,
                    alwaysUseAI: alwaysUseAIBinding
                )
            case .failed(let failure):
                AIConflictFailureView(
                    content: AIConflictFailureContent(failure, operationName: operationName),
                    alwaysUseAI: alwaysUseAIBinding,
                    onTryAgain: { AIConflictFlow.start(in: context, repository: repository) },
                    onOpenSettings: { context.actions.perform(.openSettings(.ai)) },
                    onSwitchToManual: { repository.ai.dismissConflictResolution() },
                    onAbort: { AIConflictFlow.abort(in: context, repository: repository) }
                )
            }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: .infinity, minHeight: 560, idealHeight: 620, maxHeight: .infinity)
    }

    /// "Rebase", "Merge"; the operation's name for the title and buttons.
    private var operationName: String {
        if let current = repository.operations.current {
            return OperationPanelContent.name(of: current)
        }
        switch repository.operations.conflictState {
        case .merge?: return "Merge"
        case .rebase?: return "Rebase"
        case .cherryPick?: return "Cherry-pick"
        case .revert?: return "Revert"
        case nil: return "Merge"
        }
    }

    private var alwaysUseAIBinding: Binding<Bool> {
        let preferences = context.app.preferences
        return Binding(
            get: { preferences.alwaysUseAIForConflictResolution },
            set: { preferences.alwaysUseAIForConflictResolution = $0 }
        )
    }

    static func present(for repository: RepositoryModel, in context: WindowContext) {
        presentedRepository = repository.id
        context.modals.presentSheet(id: sheetID, onDismiss: {
            presentedRepository = nil
        }) {
            AIConflictSheet(repository: repository)
        }
    }
}

/// The model's label: "Claude Sonnet · Medium".
nonisolated func aiModelLabel(_ model: ConflictResolutionModelDisplay) -> String {
    guard let effort = model.reasoningEffort else {
        return model.modelName
    }
    return "\(model.modelName) · \(formatReasoningEffort(effort))"
}

// MARK: Loading

/// What the loading phase shows.
nonisolated public struct AIConflictLoadingContent: Sendable, Equatable {
    /// "Resolving conflicts for rebase".
    public var title: String
    public var modelLabel: String
    /// "Gathering context…" or "Analyzing conflicts…".
    public var phase: String
    /// "2 of 5 files", once the model works on them.
    public var progress: String?
    /// The model's latest reasoning, oldest first; empty while it hasn't
    /// said anything.
    public var reasoning: [String]
    /// What to show while the model is silent, in turn.
    public var fallbackLines: [String]
    public var abortTitle: String

    /// The most reasoning lines shown.
    static let maxLines = 8

    public init(title: String, modelLabel: String, phase: String, progress: String?, reasoning: [String], fallbackLines: [String], abortTitle: String) {
        self.title = title
        self.modelLabel = modelLabel
        self.phase = phase
        self.progress = progress
        self.reasoning = reasoning
        self.fallbackLines = fallbackLines
        self.abortTitle = abortTitle
    }

    /// The loading view for `round`, its counts in `numberFormat`.
    init(_ round: ConflictResolutionRound, operationName: String, numberFormat: NumberFormat) {
        let gathering = round.phase == .gatheringContext
        let names = round.files.map { POSIXPath.basename($0) }
        var fallback: [String]
        if gathering {
            fallback = ["Reviewing the changes from each side", "Reading recent commit history", "Looking for related context"]
            fallback += names.prefix(4).map { "Reading \($0)" }
        } else {
            fallback = ["Cross-referencing related files", "Considering both sides of each conflict"]
            fallback += names.prefix(6).map { "Analyzing \($0)" }
            if names.count > 6 {
                fallback.append("…and \(formatCount(names.count - 6, numberFormat)) more")
            }
        }
        self.init(
            title: "Resolving conflicts for \(operationName.lowercased())",
            modelLabel: aiModelLabel(round.model),
            phase: gathering ? "Gathering context…" : "Analyzing conflicts…",
            progress: round.filesTotal > 0
                ? "\(formatCount(round.filesResolved, numberFormat)) of \(formatCount(round.filesTotal, numberFormat)) \(round.filesTotal == 1 ? "file" : "files")"
                : nil,
            reasoning: Array(round.reasoning.compactMap(Self.clean).suffix(Self.maxLines)),
            fallbackLines: fallback,
            abortTitle: "Abort \(operationName)"
        )
    }

    /// A reasoning snippet, cleaned: no Markdown headers, bullets, list
    /// numbers, bold-only labels, or fragments; emphasis removed.
    static func clean(_ snippet: String) -> String? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.range(of: "^#+\\s", options: .regularExpression) != nil
            || trimmed.range(of: "^[-*]\\s", options: .regularExpression) != nil
            || trimmed.range(of: "^\\d+\\.?$", options: .regularExpression) != nil
            || trimmed.range(of: "^\\*\\*[^*]+\\*\\*[:.]?\\s*$", options: .regularExpression) != nil {
            return nil
        }
        let isNumberedItem = trimmed.range(of: "^\\d+\\.\\s", options: .regularExpression) != nil
        guard trimmed.count >= (isNumberedItem ? 8 : 25) else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

/// The loading phase.
struct AIConflictLoadingView: View {
    let content: AIConflictLoadingContent
    var onStop: () -> Void
    var onAbort: () -> Void

    init(content: AIConflictLoadingContent, onStop: @escaping () -> Void = {}, onAbort: @escaping () -> Void = {}) {
        self.content = content
        self.onStop = onStop
        self.onAbort = onAbort
    }

    /// How long each fallback line shows.
    private static let fallbackInterval: TimeInterval = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            AIConflictSheetHeader(title: content.title, modelLabel: content.modelLabel)
            HStack {
                Label {
                    Text(content.phase)
                        .foregroundStyle(.text)
                } icon: {
                    IconCircle("sparkles", size: 24, tint: .accent)
                }
                .font(Typography.heading)
                Spacer()
                if let progress = content.progress {
                    Text(progress)
                        .font(Typography.secondaryCount)
                        .foregroundStyle(.text2)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Metrics.grid) {
                if content.reasoning.isEmpty {
                    TimelineView(.periodic(from: .now, by: Self.fallbackInterval)) { timeline in
                        fallback(at: Int(timeline.date.timeIntervalSinceReferenceDate / Self.fallbackInterval))
                    }
                } else {
                    ForEach(Array(content.reasoning.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(Typography.secondary)
                            .foregroundStyle(index == content.reasoning.count - 1 ? Color.text : Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: Metrics.insetSmall) {
                Spacer()
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Button(content.abortTitle, action: onAbort)
                    .buttonStyle(.quiet)
            }
        }
        .padding(Metrics.Sheet.padding)
        .background(Color(espalier: Palette.background))
    }

    private func fallback(at tick: Int) -> some View {
        let lines = content.fallbackLines
        let line = lines.isEmpty ? "" : lines[((tick % lines.count) + lines.count) % lines.count]
        return Text(line)
            .font(Typography.secondary)
            .foregroundStyle(.text2)
    }
}

/// The sheet's header: the title, the model, and the AI settings.
struct AIConflictSheetHeader: View {
    let title: String
    let modelLabel: String
    var onSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typography.sheetTitle)
                .foregroundStyle(.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            MonoChip(modelLabel)
            if let onSettings {
                Button(action: onSettings) {
                    Label("AI Settings", systemImage: "gearshape")
                }
                .buttonStyle(.icon)
                .tooltip("AI Settings")
                .accessibilityLabel("AI Settings")
            }
        }
    }
}

// MARK: Results

/// A file in the results: its resolution and the choices for it.
nonisolated public struct AIResolutionRow: Sendable, Equatable, Identifiable {
    /// A choice in the file's menu.
    public struct Option: Sendable, Equatable, Identifiable {
        public var title: String
        public var choice: ConflictResolutionChoice
        public var isChecked: Bool

        public var id: String {
            title
        }
    }

    public var path: String
    /// Why the file is resolved this way, or what went wrong.
    public var explanation: String?
    /// The menu's label: "The Model", "Current", "Incoming", "Keep file",
    /// "Delete file", or "Choose a resolution".
    public var choiceLabel: String
    public var options: [Option]
    /// The file has no conflicts left (resolved in an editor).
    public var isResolved: Bool

    public var id: String {
        path
    }
}

/// What the results phase shows.
nonisolated public struct AIConflictResultsContent: Sendable, Equatable {
    public var title: String
    public var modelLabel: String
    public var summary: AIConflictSummaryContent
    /// The files the model resolved.
    public var conflicted: [AIResolutionRow]
    /// The files the model skipped, with why.
    public var skipped: [AIResolutionRow]
    /// The files whose request failed or wasn't attempted.
    public var failed: [AIResolutionRow]
    /// "Retrying 2 files…" while a retry runs.
    public var retryProgress: String?
    public var abortTitle: String
    public var continueTitle: String
    public var canContinue: Bool
    public var continueHelp: String?
    public var isContinuing: Bool
    public var error: String?

    /// "5 Conflicted files", the count in `numberFormat`.
    public func conflictedHeader(_ numberFormat: NumberFormat) -> String {
        "\(formatCount(conflicted.count, numberFormat)) Conflicted \(conflicted.count == 1 ? "file" : "files")"
    }

    /// "1 Skipped by the model", the count in `numberFormat`.
    public func skippedHeader(_ numberFormat: NumberFormat) -> String {
        "\(formatCount(skipped.count, numberFormat)) Skipped by the model"
    }

    /// "2 Couldn't be resolved", the count in `numberFormat`.
    public func failedHeader(_ numberFormat: NumberFormat) -> String {
        "\(formatCount(failed.count, numberFormat)) Couldn't be resolved"
    }

    /// "2 files couldn't be resolved.", beside Try Again, the count in
    /// `numberFormat`.
    public func failedStatus(_ numberFormat: NumberFormat) -> String {
        failed.count == 1 ? "1 file couldn't be resolved." : "\(formatCount(failed.count, numberFormat)) files couldn't be resolved."
    }

    /// The paths in the Changes tab: every file the results cover.
    public var paths: [String] {
        (conflicted + skipped + failed).map(\.path)
    }

    /// Continue's tooltip while files need the user: those the model
    /// skipped, those whose request failed or wasn't attempted, or both.
    /// Nil when none do.
    public static func continueHelp(skipped: Bool, failed: Bool) -> String? {
        switch (skipped, failed) {
        case (true, false): "The model skipped some files. You'll need to resolve those yourself."
        case (false, true): "Some files couldn't be resolved. Try again, or resolve them yourself."
        case (true, true): "The model skipped some files and couldn't resolve others. Resolve them yourself, or try again."
        case (false, false): nil
        }
    }

    /// The results for a repository, counts in `numberFormat`.
    @MainActor
    static func make(
        _ results: ConflictResolutionResults,
        repository: RepositoryModel,
        operationName: String,
        isContinuing: Bool,
        error: String?,
        numberFormat: NumberFormat
    ) -> AIConflictResultsContent {
        let ai = repository.ai
        let branches = repository.operations.conflictBranches
        let roundLabels = (ours: results.summary.ourLabel, theirs: results.summary.theirLabel)
        let files = repository.changes.workingDirectory.files
        let skippedPaths = Set(results.skippedFiles.map(\.path))
        let failures = Dictionary(results.failedFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let notAttempted = Set(results.notAttemptedFiles)

        func status(_ path: String) -> ConflictedFileStatus? {
            guard let file = files.first(where: { $0.path == path }), case .conflicted(let status) = file.status else {
                return nil
            }
            return status
        }

        var conflicted: [AIResolutionRow] = []
        var failed: [AIResolutionRow] = []
        for file in files where file.status.kind == .conflicted && !skippedPaths.contains(file.path) {
            let path = file.path
            let row = resolutionRow(
                path: path,
                status: status(path),
                choice: ai.resolutionChoice(forPath: path),
                resolution: results.resolution(forPath: path),
                branches: branches,
                roundLabels: roundLabels,
                offersModel: failures[path] == nil && !notAttempted.contains(path),
                failure: failures[path]?.message ?? (notAttempted.contains(path) ? "Not attempted after an earlier request failed." : nil)
            )
            if failures[path] != nil || notAttempted.contains(path) {
                failed.append(row)
            } else {
                conflicted.append(row)
            }
        }
        let skipped = results.skippedFiles.map { skippedFile in
            resolutionRow(
                path: skippedFile.path,
                status: status(skippedFile.path),
                choice: ai.resolutionChoice(forPath: skippedFile.path),
                resolution: nil,
                branches: branches,
                roundLabels: roundLabels,
                offersModel: false,
                failure: skippedFile.reason
            )
        }

        let retryProgress = results.retry.map { round in
            let retrying = "Retrying \(formatCount(round.files.count, numberFormat)) \(round.files.count == 1 ? "file" : "files")…"
            return round.filesTotal > 0
                ? "\(retrying) \(formatCount(round.filesResolved, numberFormat)) of \(formatCount(round.filesTotal, numberFormat))"
                : retrying
        }
        let needingResolution = ai.filesNeedingResolution
        return AIConflictResultsContent(
            title: "Resolve conflicts before \(operationName)",
            modelLabel: aiModelLabel(results.model),
            summary: AIConflictSummaryContent.make(
                results.summary,
                resolvedPaths: results.resolutions.map(\.path),
                operation: results.operation,
                htmlURL: repository.record.gitHubRepository?.htmlURL
            ),
            conflicted: conflicted,
            skipped: skipped,
            failed: failed,
            retryProgress: retryProgress,
            abortTitle: "Abort \(operationName)",
            continueTitle: operationName == "Merge" ? "Commit Merge" : "Continue \(operationName)",
            canContinue: needingResolution.isEmpty && results.retry == nil && !isContinuing,
            continueHelp: continueHelp(
                skipped: needingResolution.contains { skippedPaths.contains($0) },
                failed: needingResolution.contains { !skippedPaths.contains($0) }
            ),
            isContinuing: isContinuing,
            error: error
        )
    }

    /// A file's row: its explanation, its choice, and the menu. The
    /// explanation names a side by its branch, else by the label the round
    /// gave it (`results.summary`): a rebase's unknown base is the short SHA
    /// of the commit it's being rebased onto, a revert's theirs "reverted
    /// commit".
    static func resolutionRow(
        path: String,
        status: ConflictedFileStatus?,
        choice: ConflictResolutionChoice,
        resolution: FileResolution?,
        branches: ConflictBranches?,
        roundLabels: (ours: String, theirs: String),
        offersModel: Bool,
        failure: String?
    ) -> AIResolutionRow {
        // Resolved in an editor: no markers left, or no longer conflicted.
        let isResolved: Bool = switch status {
        case nil: true
        case .conflictsWithMarkers(_, let markers, _, _)?: markers == 0
        case .manualConflict?: false
        }
        if isResolved {
            return AIResolutionRow(path: path, explanation: "No conflicts remaining", choiceLabel: "", options: [], isResolved: true)
        }

        let ours = branches?.ours
        let theirs = branches?.theirs
        let deletedSide = status.flatMap(deletedSideOfConflict)
        let labels = sideLabels(deletedSide: deletedSide, ours: ours, theirs: theirs)

        var options: [AIResolutionRow.Option] = []
        if offersModel {
            options.append(.init(title: "Use the model's suggestion", choice: .model, isChecked: choice == .model))
        }
        options.append(.init(title: labels.ours, choice: .ours, isChecked: choice == .ours))
        options.append(.init(title: labels.theirs, choice: .theirs, isChecked: choice == .theirs))

        let choiceLabel: String
        switch choice {
        case .model:
            choiceLabel = offersModel ? "The Model" : "Choose a resolution"
        case .ours, .theirs:
            if let deletedSide {
                let deletes = (deletedSide == .ours) == (choice == .ours)
                choiceLabel = deletes ? "Delete file" : "Keep file"
            } else {
                choiceLabel = choice == .ours ? "Current" : "Incoming"
            }
        }

        var explanation: String?
        switch choice {
        case .model:
            explanation = offersModel ? (resolution?.reasoning ?? failure) : failure
        case .ours, .theirs:
            if let deletedSide {
                let branch = deletedSide == .ours ? (ours ?? roundLabels.ours) : (theirs ?? roundLabels.theirs)
                let deletes = (deletedSide == .ours) == (choice == .ours)
                explanation = deletes ? "Deleting file (deleted on \(branch))" : "Keeping modified file"
            } else if choice == .ours {
                explanation = "Using changes from \(ours ?? roundLabels.ours)"
            } else {
                explanation = "Using changes from \(theirs ?? roundLabels.theirs)"
            }
        }
        return AIResolutionRow(path: path, explanation: explanation, choiceLabel: choiceLabel, options: options, isResolved: false)
    }

    /// Which side deleted the file in a delete-vs-modify conflict; nil for
    /// other conflicts.
    static func deletedSideOfConflict(_ status: ConflictedFileStatus) -> ManualConflictResolution? {
        guard case .manualConflict(let entry, _) = status else {
            return nil
        }
        if entry.us == .deleted, entry.them != .deleted {
            return .ours
        }
        if entry.them == .deleted, entry.us != .deleted {
            return .theirs
        }
        return nil
    }

    /// The side choices' labels.
    static func sideLabels(deletedSide: ManualConflictResolution?, ours: String?, theirs: String?) -> (ours: String, theirs: String) {
        switch deletedSide {
        case .ours?:
            return (
                "Delete file" + (ours.map { " on \($0)" } ?? ""),
                "Keep file" + (theirs.map { " from \($0)" } ?? "")
            )
        case .theirs?:
            return (
                "Keep file" + (ours.map { " from \($0)" } ?? ""),
                "Delete file" + (theirs.map { " on \($0)" } ?? "")
            )
        case nil:
            return (
                ours.map { "Use current file from \($0)" } ?? "Use current file",
                theirs.map { "Use incoming file from \($0)" } ?? "Use incoming file"
            )
        }
    }
}

/// The results phase: Summary and Changes, the files, and Continue.
struct AIConflictResultsView: View {
    let content: AIConflictResultsContent
    /// Whose files the rows act on.
    let repository: RepositoryModel
    @Binding var alwaysUseAI: Bool
    @State private var tab = Tab.summary
    @Environment(WindowContext.self) private var context
    @Environment(\.numberFormat) private var numberFormat

    init(content: AIConflictResultsContent, repository: RepositoryModel, alwaysUseAI: Binding<Bool>) {
        self.content = content
        self.repository = repository
        _alwaysUseAI = alwaysUseAI
    }

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case changes = "Changes"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            AIConflictSheetHeader(title: content.title, modelLabel: content.modelLabel) {
                context.actions.perform(.openSettings(.ai))
            }
            CapsuleSegmentedControl("View", selection: $tab, segments: Tab.allCases.map { CapsuleSegment($0.rawValue, value: $0) })
            // The tabs crossfade (0.15 s) in the sheet's fixed size.
            ZStack {
                tabContent
                    .id(tab)
                    .transition(.opacity)
            }
            .motion(Motion.leave, value: tab)
            if !content.failed.isEmpty {
                failedBar
            }
            if let error = content.error {
                Text(error)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color(espalier: Palette.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(Metrics.Sheet.padding)
        .background(Color(espalier: Palette.background))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .summary:
            ScrollView {
                summaryTab
                    .padding(.vertical, Metrics.grid)
            }
        case .changes:
            AIResolutionChanges(repository: repository, paths: content.paths)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        .strokeBorder(.line, lineWidth: 1)
                )
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            AIConflictSummary(content: content.summary) { url in
                context.app.integrations.openInBrowser(url)
            }
            fileSection(header: content.conflictedHeader(numberFormat), systemImage: "doc.text", rows: content.conflicted)
            if !content.skipped.isEmpty {
                fileSection(header: content.skippedHeader(numberFormat), systemImage: "exclamationmark.triangle", rows: content.skipped)
            }
            if !content.failed.isEmpty {
                fileSection(header: content.failedHeader(numberFormat), systemImage: "xmark.octagon", rows: content.failed)
            }
        }
    }

    /// The failed files' count and Try Again, or the retry's progress, below
    /// both tabs, on the attention tint.
    private var failedBar: some View {
        HStack(spacing: Metrics.insetSmall) {
            Label {
                Text(content.failedStatus(numberFormat))
                    .foregroundStyle(.text)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Color(espalier: Palette.error))
            }
            .font(Typography.secondary)
            Spacer()
            if let progress = content.retryProgress {
                ArcProgress(.small)
                Text(progress)
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                Button("Stop") {
                    repository.ai.stopResolvingConflicts()
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
            } else {
                Button("Try Again") {
                    AIConflictFlow.retry(in: context, repository: repository)
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
            }
        }
        .padding(.leading, Metrics.insetMedium)
        .padding(.trailing, Metrics.insetSmall)
        .padding(.vertical, Metrics.insetSmall)
        .background(
            Color(nsColor: StatusBarTone.attention.fill),
            in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        )
    }

    private func fileSection(header: String, systemImage: String, rows: [AIResolutionRow]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Label(header, systemImage: systemImage)
                .font(Typography.heading)
                .foregroundStyle(.text)
            ForEach(rows) { row in
                AIResolutionRowView(row: row, actions: rowActions(row))
            }
        }
    }

    private func rowActions(_ row: AIResolutionRow) -> AIResolutionRowActions {
        let path = POSIXPath.join(repository.record.path, row.path)
        let actions = context.actions
        let integrations = context.app.integrations
        return AIResolutionRowActions(
            editorName: integrations.isEditorAvailable ? integrations.editorLabel ?? "External Editor" : nil,
            choose: { choice in repository.ai.setResolutionChoice(choice, forPath: row.path) },
            openInEditor: { actions.perform(.openInEditor(path: path)) },
            openWithDefaultProgram: { actions.perform(.openWithDefaultProgram(path: path)) },
            showInFinder: { actions.perform(.showInFinder(path: path)) }
        )
    }

    private var footer: some View {
        HStack(spacing: Metrics.insetSmall) {
            Toggle("Always use AI when conflicts are detected", isOn: $alwaysUseAI)
                .toggleStyle(.checkboxMark)
                .font(Typography.secondary)
            Spacer()
            Button("Switch to Manual") {
                repository.ai.dismissConflictResolution()
            }
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .disabled(content.isContinuing)
            Button(content.abortTitle) {
                AIConflictFlow.abort(in: context, repository: repository)
            }
            .buttonStyle(.quiet)
            .disabled(content.isContinuing)
            Button(content.continueTitle) {
                AIConflictFlow.applyAndContinue(in: context, repository: repository)
            }
            .buttonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
            .disabled(!content.canContinue)
            .tooltip(content.continueHelp)
        }
    }
}

/// What a result row's menus do.
struct AIResolutionRowActions {
    /// The editor's name, when one is configured.
    var editorName: String?
    var choose: (ConflictResolutionChoice) -> Void = { _ in }
    var openInEditor: () -> Void = {}
    var openWithDefaultProgram: () -> Void = {}
    var showInFinder: () -> Void = {}
}

/// A file in the results.
struct AIResolutionRowView: View {
    let row: AIResolutionRow
    let actions: AIResolutionRowActions

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.insetSmall) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.path)
                    .font(Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let explanation = row.explanation {
                    Text(explanation)
                        .font(Typography.subheadline)
                        .foregroundStyle(.text2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Metrics.insetSmall)
            if row.isResolved {
                // In the file options button's place, centered as its
                // symbol is.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(espalier: Palette.success))
                    .frame(width: Metrics.ControlHeight.regular)
                    .accessibilityLabel("Resolved")
            } else {
                PullDownButton("Resolution for \(row.path)", value: row.choiceLabel) { [row, actions] in
                    for option in row.options {
                        MenuToggle(option.title, isOn: option.isChecked) {
                            actions.choose(option.choice)
                        }
                    }
                } label: {
                    MenuCapsuleLabel(row.choiceLabel)
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .fixedSize()
                PullDownButton("File Options") { [actions] in
                    if let editorName = actions.editorName {
                        MenuAction("Open in \(editorName)", action: actions.openInEditor)
                    }
                    MenuAction("Open with Default App", action: actions.openWithDefaultProgram)
                    MenuAction("Show in Finder", action: actions.showInFinder)
                } label: {
                    Label("File Options", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.icon)
                .fixedSize()
            }
        }
        .padding(.vertical, Metrics.grid)
        .padding(.horizontal, Metrics.ListRow.horizontalPadding)
        .tooltip(row.path)
    }
}

// MARK: Failure

/// What a failed round shows.
nonisolated public struct AIConflictFailureContent: Sendable, Equatable {
    public var title: String
    public var modelLabel: String
    public var message: String
    /// Whether the fix is in Settings ▸ AI.
    public var opensSettings: Bool
    public var abortTitle: String

    public init(title: String, modelLabel: String, message: String, opensSettings: Bool, abortTitle: String) {
        self.title = title
        self.modelLabel = modelLabel
        self.message = message
        self.opensSettings = opensSettings
        self.abortTitle = abortTitle
    }

    init(_ failure: ConflictResolutionFailure, operationName: String) {
        let opensSettings = failure.error.recoveries.contains { recovery in
            if case .openSettings = recovery { true } else { false }
        }
        self.init(
            title: "Resolve conflicts before \(operationName)",
            modelLabel: aiModelLabel(failure.model),
            message: failure.error.message,
            opensSettings: opensSettings,
            abortTitle: "Abort \(operationName)"
        )
    }
}

/// A failed round: why, and what's next.
struct AIConflictFailureView: View {
    let content: AIConflictFailureContent
    @Binding var alwaysUseAI: Bool
    var onTryAgain: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onSwitchToManual: () -> Void = {}
    var onAbort: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            AIConflictSheetHeader(title: content.title, modelLabel: content.modelLabel, onSettings: onOpenSettings)
            Label {
                Text(content.message)
                    .foregroundStyle(Color(espalier: Palette.error))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Color(espalier: Palette.error))
            }
            HStack(spacing: Metrics.insetSmall) {
                Button("Try Again", action: onTryAgain)
                    .buttonStyle(.quiet)
                if content.opensSettings {
                    Button("Open AI Settings…", action: onOpenSettings)
                        .buttonStyle(.quiet)
                }
            }
            Spacer()
            HStack(spacing: Metrics.insetSmall) {
                Toggle("Always use AI when conflicts are detected", isOn: $alwaysUseAI)
                    .toggleStyle(.checkboxMark)
                    .font(Typography.secondary)
                Spacer()
                Button("Switch to Manual", action: onSwitchToManual)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(content.abortTitle, action: onAbort)
                    .buttonStyle(.quiet)
            }
        }
        .padding(Metrics.Sheet.padding)
        .background(Color(espalier: Palette.background))
    }
}

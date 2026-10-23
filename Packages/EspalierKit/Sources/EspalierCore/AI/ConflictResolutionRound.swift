// Ported from desktop/app/src/lib/stores/app-store.ts
//
// A round's state is `RepositoryAIModel.conflictResolution`.
//
// - Written files are staged with literal pathspecs: as a pathspec,
//   `src/[id].ts` would also stage `src/i.ts` and `src/d.ts`, and a leading
//   `:` would be magic.
// - A file whose contents changed since the round read it is left alone,
//   so the user's edits aren't overwritten with the model's resolution of
//   the old contents.
// - Results apply only to the conflicts they were made for, not after
//   those conflicts are gone or a rebase has moved on to its next commit.

import AIKit
import Darwin
import EspalierSupport
import Foundation
import GitKit
import Synchronization

/// What a conflict resolution round is doing.
public enum ConflictResolutionPhase: Sendable, Equatable {
    /// Reading the conflicted files, commits, and pull requests.
    case gatheringContext
    /// The model is working.
    case analyzing
}

/// A conflict resolution round while it runs: the loading phase.
public struct ConflictResolutionRound: Sendable, Equatable {
    /// The operation whose conflicts are resolved ("Resolving conflicts for
    /// <operation>"); nil without one.
    public let operation: MultiCommitOperationKind?
    /// The model, for the header ("<model> · <Effort>").
    public let model: ConflictResolutionModelDisplay
    /// The conflicted files being resolved.
    public let files: [String]
    public internal(set) var phase: ConflictResolutionPhase
    /// Files resolved so far, of `filesTotal` (the files sent to the model;
    /// 0 until it starts).
    public internal(set) var filesResolved: Int
    public internal(set) var filesTotal: Int
    /// The model's reasoning so far, a sentence at a time, oldest first (at
    /// most `maxReasoningSnippets`).
    public internal(set) var reasoning: [String]
    /// Whether the round started by itself: "Always use AI when conflicts
    /// are detected", or an earlier round of the same operation.
    public let startedAutomatically: Bool

    /// The most reasoning snippets kept.
    public static let maxReasoningSnippets = 50

    init(
        operation: MultiCommitOperationKind?,
        model: ConflictResolutionModelDisplay,
        files: [String],
        phase: ConflictResolutionPhase,
        startedAutomatically: Bool
    ) {
        self.operation = operation
        self.model = model
        self.files = files
        self.phase = phase
        filesResolved = 0
        filesTotal = 0
        reasoning = []
        self.startedAutomatically = startedAutomatically
    }

    /// Takes in progress AIKit reported, in order.
    mutating func apply(_ progress: [ConflictResolutionProgress]) {
        for update in progress {
            phase = .analyzing
            filesResolved = update.filesResolved
            filesTotal = update.filesTotal
            if let snippet = update.reasoningSnippet {
                reasoning.append(snippet)
            }
        }
        if reasoning.count > Self.maxReasoningSnippets {
            reasoning.removeFirst(reasoning.count - Self.maxReasoningSnippets)
        }
    }
}

/// A file the model couldn't resolve because its request failed.
public struct ConflictResolutionFailedFile: Sendable, Hashable {
    public let path: String
    /// The provider error's title, when the provider failed.
    public let title: String?
    /// Why the request failed.
    public let message: String
}

/// What a finished round produced: the results phase.
///
/// Nothing is written until `RepositoryAIModel.applyResolutions()`. The
/// per-file choices are the operation's manual resolutions
/// (`RepositoryAIModel.setResolutionChoice(_:forPath:)`).
public struct ConflictResolutionResults: Sendable, Equatable {
    /// The operation whose conflicts were resolved.
    public let operation: MultiCommitOperationKind?
    /// The model that resolved them.
    public let model: ConflictResolutionModelDisplay
    /// A retry of the failed and unattempted files, while it runs.
    public internal(set) var retry: ConflictResolutionRound?

    /// Everything the round (and its retries) produced.
    var outcome: ConflictResolutionOutcome
    /// What was sent to the model, to retry files and to check them before
    /// writing.
    let context: ConflictResolutionContext
    /// The conflicts the results are for.
    let key: ConflictRoundKey

    /// The model's resolutions (full file contents, or a keep or delete
    /// choice for delete-vs-modify conflicts), with its reasoning.
    public var resolutions: [FileResolution] {
        outcome.resolutions
    }

    /// The summary card: the model's Markdown, both sides' labels, and the
    /// pull requests and commits it cited.
    public var summary: AIResolutionSummary {
        outcome.summary
    }

    /// Files that weren't sent to the model, with why: they need resolving
    /// by hand.
    public var skippedFiles: [AISkippedFile] {
        outcome.skippedFiles
    }

    /// Files whose request failed: retry them, or resolve them by hand.
    public var failedFiles: [ConflictResolutionFailedFile] {
        outcome.failedFiles.map { file in
            let failure = aiFailure(file.error) ?? .provider(title: nil, message: aiErrorDescription(file.error.underlyingError))
            let title: String? = if case .provider(let title, _) = failure { title } else { nil }
            return ConflictResolutionFailedFile(path: file.path, title: title, message: failure.message)
        }
    }

    /// Files that weren't attempted because an earlier request failed in a
    /// way that would fail them too: retry them with the failed files.
    public var notAttemptedFiles: [String] {
        outcome.notAttemptedFiles
    }

    /// The model's resolution of a file.
    public func resolution(forPath path: String) -> FileResolution? {
        resolutions.first { JSCompat.strictEquals($0.path, path) }
    }

    public static func == (lhs: ConflictResolutionResults, rhs: ConflictResolutionResults) -> Bool {
        lhs.operation == rhs.operation
            && lhs.model == rhs.model
            && lhs.retry == rhs.retry
            && lhs.key == rhs.key
            && lhs.resolutions == rhs.resolutions
            && lhs.summary == rhs.summary
            && lhs.skippedFiles == rhs.skippedFiles
            && lhs.failedFiles == rhs.failedFiles
            && lhs.notAttemptedFiles == rhs.notAttemptedFiles
    }
}

/// A round that failed: shown in place of the results, with its error.
public struct ConflictResolutionFailure: Sendable, Equatable {
    public let operation: MultiCommitOperationKind?
    public let model: ConflictResolutionModelDisplay
    public let error: OperationError
}

/// How a conflicted file is resolved in the results: the model's
/// resolution, or one side.
public enum ConflictResolutionChoice: Sendable, Hashable {
    /// The model's resolution ("Use the model's suggestion").
    case model
    /// Our side ("Use <ours>'s Version").
    case ours
    /// Their side ("Use <theirs>'s Version").
    case theirs
}

/// What applying a round's resolutions did.
public struct AppliedConflictResolutions: Sendable, Equatable {
    /// Why a resolution wasn't written.
    public enum Reason: Sendable, Equatable {
        /// The user chose a side for the file; continuing applies it.
        case userChoseSide
        /// The file is no longer conflicted, or has no conflict markers
        /// left: the user resolved it, and their resolution stands.
        case alreadyResolved
        /// The file changed on disk since the model read it: writing the
        /// model's resolution would discard those changes.
        case changedSinceResolution
        /// The path doesn't resolve inside the repository.
        case outsideRepository
    }

    /// A resolution that wasn't written.
    public struct NotWritten: Sendable, Equatable {
        public let path: String
        public let reason: Reason
    }

    /// Files written with the model's resolution and staged.
    public internal(set) var written: [String] = []
    /// Delete-vs-modify conflicts given the model's keep or delete choice as
    /// a manual resolution, which continuing the operation applies.
    public internal(set) var sidesChosen: [String] = []
    /// Resolutions left unwritten, with why.
    public internal(set) var notWritten: [NotWritten] = []
}

/// The conflicts a round is for: the operation's conflict state without the
/// user's choices, and HEAD, which moves on between a rebase's (or a
/// multi-commit cherry-pick's) rounds.
struct ConflictRoundKey: Sendable, Equatable {
    let conflictState: ConflictState
    let head: String?

    init(_ conflictState: ConflictState, head: String?) {
        self.conflictState = conflictState.withManualResolutions([:])
        self.head = head
    }
}

/// Carries AIKit's progress (reported from any thread) to the main actor,
/// in order: counts and reasoning snippets are applied in one main-actor
/// task per turn, and none is dropped.
final class ConflictResolutionProgressRelay: Sendable {
    private struct State {
        var pending: [ConflictResolutionProgress] = []
        var isScheduled = false
    }

    private let state = Mutex(State())
    private let apply: @MainActor @Sendable ([ConflictResolutionProgress]) -> Void

    init(apply: @escaping @MainActor @Sendable ([ConflictResolutionProgress]) -> Void) {
        self.apply = apply
    }

    func send(_ progress: ConflictResolutionProgress) {
        let schedule = state.withLock { state in
            state.pending.append(progress)
            if state.isScheduled {
                return false
            }
            state.isScheduled = true
            return true
        }
        if schedule {
            Task { @MainActor in
                self.flush()
            }
        }
    }

    /// Applies what's pending now.
    @MainActor
    func flush() {
        let pending = state.withLock { state in
            state.isScheduled = false
            defer { state.pending = [] }
            return state.pending
        }
        if !pending.isEmpty {
            apply(pending)
        }
    }
}

// MARK: - Writing resolutions

/// Writes resolved files in place, off the main actor.
enum ConflictResolutionWriter {
    /// A resolution to write.
    struct PendingWrite: Sendable {
        let path: String
        let content: String
        /// The file's contents when the model read it.
        let expectedContent: String
    }

    enum Outcome: Sendable, Equatable {
        case written
        case changedSinceResolution
        case outsideRepository
    }

    /// Writes each file whose contents are still what the model read,
    /// keeping its inode, mode, and symbolic links, and never creating one
    /// that's gone.
    ///
    /// - Throws: When a write fails; files written before it stay written.
    @concurrent
    static func write(_ files: [PendingWrite], repositoryPath: String) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for file in files {
            let absolutePath: String?
            do {
                absolutePath = try ConflictContextGatherer.resolveWithin(repositoryPath, file.path)
            } catch {
                outcomes.append(.changedSinceResolution)
                continue
            }
            guard let absolutePath else {
                outcomes.append(.outsideRepository)
                continue
            }
            guard let onDisk = FileManager.default.contents(atPath: absolutePath), onDisk == Data(file.expectedContent.utf8) else {
                outcomes.append(.changedSinceResolution)
                continue
            }
            try writeInPlace(Data(file.content.utf8), to: absolutePath)
            outcomes.append(.written)
        }
        return outcomes
    }

    /// Replaces a file's contents without replacing the file.
    static func writeInPlace(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
    }

    /// Stages files whose conflicts were resolved. Paths are literal
    /// pathspecs.
    static func stage(_ paths: [String], in repository: Repository) async throws {
        guard !paths.isEmpty else {
            return
        }
        try await git(["add", "--"] + literalPathspecs(paths), repository.path, "applyConflictResolutions")
    }
}

// MARK: - Errors

/// The AI failure an AIKit error stands for, or nil for other errors (git's,
/// the file system's).
func aiFailure(_ error: any Error) -> AIFailure? {
    switch error {
    case let error as AIConflictResolutionError:
        return aiFailure(error.underlyingError) ?? .provider(title: nil, message: aiErrorDescription(error.underlyingError))
    case let error as AIProviderError:
        let info = getAIErrorDisplayInfo(error)
        let message = info.retryAfterMessage.map { "\(info.message)\n\n\($0)" } ?? info.message
        return .provider(title: info.title, message: message)
    case let error as AIResponseError:
        return .provider(title: nil, message: error.message)
    case let error as AIValidationError:
        return .provider(title: nil, message: error.message)
    case let error as AIModelRequestError:
        return .modelUnavailable(error.message)
    case let error as AIModelNotConfiguredError:
        return .modelUnavailable(error.message)
    default:
        return nil
    }
}

/// What the user can do about an AI failure: "Open Settings" (Settings ▸
/// AI) when the fix is there (no provider or model, a missing credential,
/// a rejected key, an unknown model, a bad base URL); nothing for failures
/// trying again may fix.
func aiRecoveries(for failure: AIFailure, underlying error: (any Error)?) -> [Recovery] {
    switch failure {
    case .noProvider, .modelSelectionRequired, .modelUnavailable:
        return [.openSettings(.ai)]
    case .provider:
        var underlying = error
        while let wrapper = underlying as? AIConflictResolutionError {
            underlying = wrapper.underlyingError
        }
        switch (underlying as? AIProviderError)?.kind {
        case .authentication?, .permissionDenied?, .notFound?, .invalidConfiguration?:
            return [.openSettings(.ai)]
        default:
            return []
        }
    case .consentRequired, .disabled:
        return []
    }
}

/// The `OperationError` for what an AI feature threw: a cancellation, an AI
/// failure with `getAIErrorDisplayInfo`'s title and message, or git's error
/// classified as a load's (without side effects).
func aiOperationError(_ error: any Error, operation: OperationKind, record: RepositoryRecord, cancelled: Bool) async -> OperationError {
    if let error = error as? OperationError {
        return error
    }
    if cancelled || error is CancellationError || error is CommitMessageGenerationCancelledError || error is AIConflictResolutionAbortError {
        return OperationError(.cancelled(.userCancelled), operation: operation, repositoryID: record.id, underlying: error)
    }
    if let failure = aiFailure(error) {
        return OperationError(
            .ai(failure),
            operation: operation,
            repositoryID: record.id,
            underlying: error,
            recoveries: aiRecoveries(for: failure, underlying: error)
        )
    }
    return await ErrorClassifier.classify(
        error,
        descriptor: OperationDescriptor(kind: operation, lanes: []),
        record: record,
        context: ClassificationContext()
    )
}

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "clone")

/// A clone's identity in the selection.
public struct CloneID: Hashable, Sendable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// A clone in progress, with its progress.
public struct CloneTask: Sendable, Identifiable, Equatable {
    /// Where a clone is.
    public enum Phase: Sendable, Equatable {
        /// Git is cloning; `CloneCoordinator.cancel(_:)` stops it.
        case cloning
        /// Cancelled: git is stopping, and what it cloned is being removed.
        case cancelling
        /// Git has finished and the repository is being added to the list;
        /// too late to cancel.
        case adding
    }

    public let id: CloneID
    public let url: String
    public let path: String
    /// The latest progress: "Cloning into <path>", git's description, and a
    /// value (0 until git reports some).
    public var progress: CloneProgress?
    public var phase: Phase
    /// The missing repository being cloned again ("Clone Again"), if any.
    public let repositoryID: RepositoryID?

    public init(
        id: CloneID = CloneID(),
        url: String,
        path: String,
        progress: CloneProgress? = nil,
        phase: Phase = .cloning,
        repositoryID: RepositoryID? = nil
    ) {
        self.id = id
        self.url = url
        self.path = path
        self.progress = progress
        self.phase = phase
        self.repositoryID = repositoryID
    }

    /// The repository's name: the URL's last component without `.git`.
    /// Cloning view: "Cloning <name>".
    public var name: String {
        POSIXPath.basename(url, ".git")
    }

    /// Whether `CloneCoordinator.cancel(_:)` still stops it ("Cancel Clone").
    public var canCancel: Bool {
        phase == .cloning
    }
}

/// What to clone, and where.
public struct CloneRequest: Sendable, Hashable {
    /// The URL to clone, as resolved (`resolveCloneInfo(_:)`).
    public var url: String
    /// The folder to clone into: empty or not yet there.
    public var path: String
    /// The branch to check out; the default branch for an empty repository
    /// (the API's, from `resolveCloneInfo(_:)`).
    public var options: CloneOptions

    public init(url: String, path: String, options: CloneOptions = CloneOptions()) {
        self.url = url
        self.path = path
        self.options = options
    }
}

/// What a finished clone added, and what to ask the user next.
public struct CloneResult: Sendable, Equatable {
    /// The repository at the clone's folder: added to the list, or already
    /// in it.
    public let repositoryID: RepositoryID
    /// The repository uses Git LFS: ask to initialize it
    /// (`AppModel.lfsInitializationPrompt(for:)`, then `initializeLFS(in:)`).
    public let usesLFS: Bool
    /// The repository is a fork on GitHub: ask how it will be used (the
    /// answer goes to `AppModel.setForkContributionTarget(_:for:)`).
    public let isFork: Bool

    public init(repositoryID: RepositoryID, usesLFS: Bool, isFork: Bool) {
        self.repositoryID = repositoryID
        self.usesLFS = usesLFS
        self.isFork = isFork
    }
}

/// Clones repositories: the clones in progress, cloning, cancelling, and
/// cloning a missing repository again.
///
/// A clone shows in the repository list (`AppModel.repositoryListGroups`)
/// and is selected (`AppSelection.clone`) while git runs. The selection is
/// an identifier, so it stays on the clone while the list changes. When the
/// clone ends, the task leaves the list; if it was still selected, the
/// selection moves to the repository it added, or after a failure or a
/// cancel, back to what was selected before.
@MainActor @Observable
public final class CloneCoordinator {
    /// The clones in progress, oldest first.
    public internal(set) var clones: [CloneTask] = []

    @ObservationIgnored weak var app: AppModel?
    /// The git process of each clone while it runs.
    @ObservationIgnored private var jobs: [CloneID: CloneJob] = [:]
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// The clone in progress with `id`, if any.
    public func task(_ id: CloneID) -> CloneTask? {
        clones.first { $0.id == id }
    }

    // MARK: Cloning

    /// Clones `request.url` into `request.path` and adds the repository to
    /// the list.
    ///
    /// 1. The folder is checked again (`validateClonePath(_:)`) and
    ///    remembered as the place for the next clone (`lastCloneLocation`,
    ///    its parent folder).
    /// 2. The clone appears in `clones` and is selected; `progress` follows
    ///    git (and Git LFS).
    /// 3. When git finishes, the repository is added (`addRepositories`):
    ///    its remotes, GitHub association, and whether it uses Git LFS.
    ///    A missing repository already listed at that folder is found again.
    /// 4. The clone leaves the list; if it was still selected, the
    ///    repository is selected.
    ///
    /// - Returns: The repository, and whether to ask about Git LFS and the
    ///   fork.
    /// - Throws: A precondition error for a folder that can't be cloned into
    ///   or one being cloned into already; `cancelled(.userCancelled)` after
    ///   `cancel(_:)`; otherwise git's error, titled "Clone failed", with
    ///   "Retry Clone" (`CloneRetry`).
    public func clone(_ request: CloneRequest) async throws(OperationError) -> CloneResult {
        let app = try requireApp(nil)
        // The URL is trimmed before cloning.
        let request = CloneRequest(url: JSCompat.trim(request.url), path: request.path, options: request.options)
        try checkNotCloning(into: request.path, repositoryID: nil)
        try await checkDestination(request.path, repositoryID: nil)
        // The folder the clone went into is remembered for the next clone.
        app.preferences.lastCloneLocation = POSIXPath.resolve(request.path, "..")
        return try await run(request, cloningAgain: nil)
    }

    /// Clones `url` into `path` and adds the repository to the list; see
    /// `clone(_:)`, which also says whether to ask about Git LFS and the
    /// fork.
    @discardableResult
    public func clone(_ url: String, to path: String, options: CloneOptions = CloneOptions()) async throws(OperationError) -> RepositoryID {
        try await clone(CloneRequest(url: url, path: path, options: options)).repositoryID
    }

    /// Clones a missing repository again into its folder, from its GitHub
    /// repository's clone URL, then finds it again ("Clone Again").
    ///
    /// While git runs the clone is selected; once found again, the
    /// repository is selected if the clone still was.
    ///
    /// - Throws: A precondition error when the repository isn't in the list
    ///   or has no clone URL, or its folder can't be cloned into; otherwise
    ///   as `clone(_:)`, with "Retry Clone" cloning it again.
    public func cloneAgain(_ id: RepositoryID) async throws(OperationError) {
        let app = try requireApp(id)
        guard let record = app.record(id) else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .clone, repositoryID: id)
        }
        guard let url = record.gitHubRepository?.cloneURL, !url.isEmpty else {
            throw OperationError(
                .precondition("Espalier doesn't know where \(record.name) was cloned from."),
                operation: .clone,
                repositoryID: id
            )
        }
        try checkNotCloning(into: record.path, repositoryID: id)
        try await checkDestination(record.path, repositoryID: id)
        _ = try await run(CloneRequest(url: url, path: record.path), cloningAgain: id)
    }

    /// Runs a failed clone again ("Retry Clone"), with what it was given:
    /// the dialog's clone (whose result the UI follows up on) or Clone Again
    /// (nil).
    @discardableResult
    public func retry(_ retry: CloneRetry) async throws(OperationError) -> CloneResult? {
        if let id = retry.missingRepositoryID {
            try await cloneAgain(id)
            return nil
        }
        try checkNotCloning(into: retry.request.path, repositoryID: nil)
        try await checkDestination(retry.request.path, repositoryID: nil)
        return try await run(retry.request, cloningAgain: nil)
    }

    // MARK: Cancelling

    /// Cancels a clone ("Cancel Clone"): git and every process it started
    /// stop, what it cloned is removed (the folder, or what it put in a
    /// folder that was empty), and the clone leaves the list. Its `clone`
    /// call throws `cancelled(.userCancelled)`. Once git has finished
    /// (`phase == .adding`) it's too late, and nothing happens.
    public func cancel(_ id: CloneID) {
        guard let index = clones.firstIndex(where: { $0.id == id }), clones[index].phase == .cloning else {
            return
        }
        guard let job = jobs[id] else {
            // No git process runs for it here.
            finish(id, selecting: nil, previous: nil)
            return
        }
        clones[index].phase = .cancelling
        job.cancel()
    }

    /// Removes a clone from the list, which cancels it.
    public func remove(_ id: CloneID) {
        cancel(id)
    }

    /// Cancels every clone and waits until they've ended (quitting).
    func cancelAll() async {
        for task in clones {
            cancel(task.id)
        }
        await idle()
    }

    // MARK: Waiting

    /// Whether no clone is running.
    public var isIdle: Bool {
        running == 0
    }

    /// Waits until no clone is running, the repositories they add added.
    public func idle() async {
        while running > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    // MARK: Running a clone

    private func run(_ request: CloneRequest, cloningAgain missingID: RepositoryID?) async throws(OperationError) -> CloneResult {
        let app = try requireApp(missingID)
        // Checked again after the destination's check, which waited.
        try checkNotCloning(into: request.path, repositoryID: missingID)

        running += 1
        defer { runDidEnd() }

        // The clone shows at once, with its first progress.
        let task = CloneTask(
            url: request.url,
            path: request.path,
            progress: CloneProgress(value: 0, title: "Cloning into \(request.path)"),
            repositoryID: missingID
        )
        clones.append(task)
        let previousSelection = app.selection
        app.select(.clone(task.id))

        // What cancelling removes: the folder git makes, or what git put in
        // the empty folder that was there.
        let destinationExisted = FileManager.default.fileExists(atPath: request.path)
        let relay = ProgressRelay<CloneProgress> { [weak self] progress in
            self?.update(task.id) { $0.progress = progress }
        }
        let environment = app.environment
        // Git runs in a task of its own: only `cancel(_:)` stops it, never
        // the caller's cancellation.
        let gitTask = Task { () async throws in
            // The user's shell environment loads at launch; a clone waits for
            // it, as operations do, so cloning over SSH finds the agent the
            // shell sets up.
            await environment.git.shellEnvironment?.waitUntilLoaded()
            try Task.checkCancellation()
            try await environment.withRuntimes {
                try await GitKit.clone(request.url, request.path, request.options) { progress in
                    relay.send(progress)
                }
            }
        }
        let job = CloneJob(gitTask)
        jobs[task.id] = job
        let outcome = await gitTask.result
        jobs[task.id] = nil
        relay.flush()

        if job.isCancelled {
            logger.info("Cancelled a clone; removing what it cloned")
            await removeClone(at: request.path, keepingFolder: destinationExisted)
            finish(task.id, selecting: nil, previous: previousSelection)
            throw OperationError(.cancelled(.userCancelled), operation: .clone, repositoryID: missingID)
        }
        if case .failure(let error) = outcome {
            finish(task.id, selecting: nil, previous: previousSelection)
            throw await classify(error, request: request, cloningAgain: missingID)
        }

        update(task.id) { $0.phase = .adding }
        if let missingID {
            // Clone Again: the repository is in the list, missing; look for
            // it again.
            await app.checkRepositoryAgain(missingID)
            finish(task.id, selecting: missingID, previous: previousSelection)
            return CloneResult(repositoryID: missingID, usesLFS: false, isFork: false)
        }

        let added: AddRepositoriesResult
        do {
            added = try await app.addRepositories([request.path])
        } catch {
            finish(task.id, selecting: nil, previous: previousSelection)
            throw error
        }
        guard let id = added.repositories.first else {
            finish(task.id, selecting: nil, previous: previousSelection)
            throw OperationError(
                .precondition(added.invalidPathsMessage ?? "\(request.path) isn't a Git repository."),
                operation: .clone
            )
        }
        if added.existing.contains(id), app.record(id)?.isMissing == true {
            // The clone went where a missing repository was: it's back.
            await app.checkRepositoryAgain(id)
        }
        finish(task.id, selecting: id, previous: previousSelection)
        return CloneResult(
            repositoryID: id,
            usesLFS: added.usingLFS.contains(id),
            isFork: app.record(id).map(isRepositoryWithForkedGitHubRepository) ?? false
        )
    }

    /// Takes the clone out of the list. If it was selected, selects the
    /// repository it added, else what was selected before it (if that's
    /// still there), else the most recent or first repository.
    private func finish(_ id: CloneID, selecting repositoryID: RepositoryID?, previous: AppSelection?) {
        jobs[id] = nil
        if let app, app.selection == .clone(id) {
            if let repositoryID, app.record(repositoryID) != nil {
                app.select(.repository(repositoryID))
            } else {
                app.select(fallbackSelection(after: id, previous: previous, in: app))
            }
        }
        clones.removeAll { $0.id == id }
    }

    private func fallbackSelection(after id: CloneID, previous: AppSelection?, in app: AppModel) -> AppSelection? {
        switch previous {
        case .repository(let previousID)? where app.record(previousID) != nil:
            return previous
        case .clone(let previousID)? where previousID != id && task(previousID) != nil:
            return previous
        default:
            let next = app.recentRepositoryIDs.first { app.record($0) != nil } ?? app.repositories.first?.id
            return next.map(AppSelection.repository)
        }
    }

    private func update(_ id: CloneID, _ change: (inout CloneTask) -> Void) {
        guard let index = clones.firstIndex(where: { $0.id == id }) else {
            return
        }
        var task = clones[index]
        change(&task)
        if task != clones[index] {
            clones[index] = task
        }
    }

    private func runDidEnd() {
        running -= 1
        guard running == 0, !idleWaiters.isEmpty else {
            return
        }
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Refuses a folder a clone is going into already: two clones would
    /// write into one repository.
    private func checkNotCloning(into path: String, repositoryID: RepositoryID?) throws(OperationError) {
        if let other = clones.first(where: { pathsMatch($0.path, path) }) {
            throw OperationError(
                .precondition("Espalier is already cloning into \(other.path)."),
                operation: .clone,
                repositoryID: repositoryID
            )
        }
    }

    /// Checks the folder before cloning into it.
    private func checkDestination(_ path: String, repositoryID: RepositoryID?) async throws(OperationError) {
        guard !path.isEmpty else {
            throw OperationError(.precondition("Couldn't create a folder at this path."), operation: .clone, repositoryID: repositoryID)
        }
        // Git resolves a relative path against its own working directory and
        // this process against another, so a cancelled clone could remove
        // the wrong folder's contents. The dialog always gives a full path.
        guard path.hasPrefix("/") else {
            throw OperationError(.precondition("Choose the folder to clone into by its full path."), operation: .clone, repositoryID: repositoryID)
        }
        if let problem = await validateClonePath(path) {
            throw OperationError(.precondition(problem.message), operation: .clone, repositoryID: repositoryID)
        }
    }

    /// Git's error as "Clone failed", with "Retry Clone". A missing
    /// repository cloned again isn't passed as the record, so its errors
    /// aren't taken for the repository being missing.
    private func classify(_ error: any Error, request: CloneRequest, cloningAgain missingID: RepositoryID?) async -> OperationError {
        let retry = CloneRetry(request: request, missingRepositoryID: missingID)
        let classified = await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: .clone, lanes: [], retry: retry),
            record: nil,
            context: ClassificationContext()
        )
        logger.error("Clone failed: \(classified.message, privacy: .private)")
        guard let missingID else {
            return classified
        }
        return OperationError(
            classified.reason,
            operation: .clone,
            repositoryID: missingID,
            retry: classified.retry,
            underlying: classified.underlying,
            recoveries: classified.recoveries
        )
    }

    private func requireApp(_ id: RepositoryID?) throws(OperationError) -> AppModel {
        guard let app else {
            throw OperationError(.precondition("Espalier is quitting."), operation: .clone, repositoryID: id)
        }
        return app
    }
}

/// A clone's git process, and whether the user cancelled it.
@MainActor
private final class CloneJob {
    private let gitTask: Task<Void, any Error>
    private(set) var isCancelled = false

    init(_ gitTask: Task<Void, any Error>) {
        self.gitTask = gitTask
    }

    func cancel() {
        isCancelled = true
        gitTask.cancel()
    }
}

/// Whether two paths name the same folder, as written: normalized, without a
/// trailing slash.
private func pathsMatch(_ x: String, _ y: String) -> Bool {
    func folder(_ path: String) -> String {
        let normalized = POSIXPath.normalize(path)
        return normalized.count > 1 && JSCompat.endsWith(normalized, "/") ? String(normalized.dropLast()) : normalized
    }
    return JSCompat.strictEquals(folder(x), folder(y))
}

/// Removes what a cancelled clone left: the folder, or what's in it when it
/// was there (empty) before. Git removes it itself when cancelled while
/// fetching, but keeps it once it has started checking out.
@concurrent
private func removeClone(at path: String, keepingFolder: Bool) async {
    let manager = FileManager.default
    do {
        if keepingFolder {
            for name in try manager.contentsOfDirectory(atPath: path) {
                try manager.removeItem(atPath: POSIXPath.join(path, name))
            }
        } else if manager.fileExists(atPath: path) {
            try manager.removeItem(atPath: path)
        }
    } catch {
        logger.error("Could not remove a cancelled clone: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Retry

/// Runs a failed clone again: "Retry Clone".
public struct CloneRetry: RetryableOperation {
    /// What was cloned, and where.
    public let request: CloneRequest
    /// The missing repository that was being cloned again, if any.
    public let missingRepositoryID: RepositoryID?

    public init(request: CloneRequest, missingRepositoryID: RepositoryID? = nil) {
        self.request = request
        self.missingRepositoryID = missingRepositoryID
    }

    public var kind: OperationKind {
        .clone
    }

    /// The repository's name, for "Would you like to retry cloning <name>?".
    public var displayName: String? {
        POSIXPath.basename(request.url, ".git")
    }

    @discardableResult
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        _ = try await app.clones.retry(self)
        return .nothing
    }
}

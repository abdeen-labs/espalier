// Ported from desktop/app/src/lib/git/assisted-commit/snapshot.ts and
// plan.ts
//
// - A partial selection is carried over to the frozen diff's lines
//   (`DiffSelection.carried(to:selectableLines:)`), as an ordinary partial
//   commit carries it to the diff it reads, so lines are matched by their
//   text rather than their positions in the diff the user saw.
// - Fully selected files are cleaned in a private index seeded from HEAD
//   (`git update-index`), so attributes, filters, line endings, and modes
//   work as they do for an ordinary commit.
// - A selected file whose cleaned content is the same as HEAD's adds no
//   unit, rather than failing the run.
// - A partial selection that would keep a line without its newline in the
//   middle of the file (an unselected change to the last line) fails rather
//   than joining two lines.

import EspalierSupport
import Foundation

/// The most bytes (base plus selected file) a file's changes are split
/// into hunks at: larger files are one unit.
let assistedMaximumSplittableBytes = 4 * 1024 * 1024

/// A selected file, frozen.
struct AssistedFrozenFile: Sendable {
    let change: WorkingDirectoryFileChange
    let state: AssistedCapturedFileState
    /// HEAD's entry: at the old path for a rename.
    let base: AssistedTreeEntry?
    /// The selected entry, nil for a deletion.
    let selected: AssistedTreeEntry?
    /// HEAD's bytes, which hunks splice.
    let baseBytes: Data
    /// The ID of the file's one unit, when it can't be split.
    let atomicID: String?
    /// The file's hunks, in order, when it can be.
    let hunks: [AssistedFrozenHunk]

    var path: String {
        change.path
    }

    /// The path a rename removes.
    var removedPath: String? {
        if case .renamed(let oldPath, _, _) = change.status {
            return oldPath
        }
        return nil
    }

    /// The tree changes that commit the file with `entry` (its selected
    /// entry by default).
    func treeUpdates(_ entry: AssistedTreeEntry?? = nil) -> [(path: String, entry: AssistedTreeEntry?)] {
        let entry = entry ?? selected
        var updates: [(path: String, entry: AssistedTreeEntry?)] = []
        if let removedPath {
            updates.append((path: removedPath, entry: nil))
        }
        updates.append((path: path, entry: entry))
        return updates
    }
}

/// One hunk of a file's selected changes: HEAD's lines `start..<end` become
/// `replacement`.
struct AssistedFrozenHunk: Sendable {
    let id: String
    let start: Int
    let end: Int
    let replacement: Data
}

/// Runs `body` in a task of its own, which the caller's cancellation doesn't
/// reach: cancelling the caller cancels `cancellation` instead, so git
/// that's running finishes and the run stops at its next boundary.
func assistedShielded<T: Sendable>(
    _ cancellation: AssistedCommitCancellation,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task { try await body() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        cancellation.cancel()
    }
}

/// The selected changes, frozen: their bytes, HEAD, and the index, as they
/// were when it was captured. Later work never reads the files again to
/// build commits; it only checks they haven't changed.
///
/// Only `analysis` may go to a planner. The rest is Espalier's.
///
/// Capture with `capture(_:_:options:)`, plan from `analysis`, check the
/// plan with `validate(_:options:)`, and run it with `execute(_:options:)`,
/// which disposes the snapshot. A snapshot that isn't executed is disposed
/// with `dispose()` (`withAssistedCommitSnapshot` does it).
public actor AssistedCommitSnapshot {
    public nonisolated let id: String
    public nonisolated let analysis: AssistedCommitAnalysis
    public nonisolated let originalHead: AssistedCommitHead
    /// The tree with every selected change.
    public nonisolated let selectedTree: String
    /// The selection as captured, for restoring it after a failure. After a
    /// selected file changed, carry it over to the file's new diff rather
    /// than reusing its line indexes.
    public nonisolated let originalSelection: [WorkingDirectoryFileChange]

    let identity: AssistedRepositoryIdentity
    let request: AssistedCommitRequest
    let files: [AssistedFrozenFile]
    let baseTree: String
    let privateRepository: AssistedPrivateRepository

    enum Phase {
        case captured
        case validating
        case executing
        case disposed
    }

    var phase = Phase.captured
    /// The plans this snapshot validated, by token: their trees.
    var validatedPlans: [UUID: [String]] = [:]

    private init(
        id: String,
        analysis: AssistedCommitAnalysis,
        identity: AssistedRepositoryIdentity,
        request: AssistedCommitRequest,
        files: [AssistedFrozenFile],
        baseTree: String,
        selectedTree: String,
        privateRepository: AssistedPrivateRepository
    ) {
        self.id = id
        self.analysis = analysis
        self.originalHead = identity.originalHead
        self.selectedTree = selectedTree
        self.originalSelection = request.files
        self.identity = identity
        self.request = request
        self.files = files
        self.baseTree = baseTree
        self.privateRepository = privateRepository
    }

    // MARK: Capture

    /// Freezes the selected changes.
    ///
    /// Checks the selection first: no conflicts or submodules, no two files
    /// at one path, no rename overlapping another, a branch or detached HEAD
    /// with no merge, rebase, cherry-pick, revert, or bisect in progress,
    /// and file-backed refs. Then reads each selected file, cleans it as
    /// `git add` would, and splits text changes into hunks; binary, renamed,
    /// deleted, symbolic link, mode-changing, and very large changes are
    /// one unit each. Finally checks that HEAD, the index, and the files
    /// are as they were.
    ///
    /// The repository's index and working tree aren't touched.
    ///
    /// - Throws: `AssistedCommitError`: `unsafeSelection` for what can't be
    ///   committed this way, `selectionChanged`, `repositoryChanged`, or
    ///   `indexChanged` when something changed during capture, `cancelled`.
    public static func capture(
        _ repository: Repository,
        _ request: AssistedCommitRequest,
        options: AssistedCommitOptions = AssistedCommitOptions()
    ) async throws -> AssistedCommitSnapshot {
        try await assistedShielded(options.cancellation) {
            do {
                return try await captureUnshielded(repository, request, options)
            } catch {
                throw AssistedCommitError.wrapping(error, .unsafeSelection, "Espalier couldn't read the selected changes.")
            }
        }
    }

    private static func captureUnshielded(
        _ repository: Repository,
        _ input: AssistedCommitRequest,
        _ options: AssistedCommitOptions
    ) async throws -> AssistedCommitSnapshot {
        let cancellation = options.cancellation
        try cancellation.check()
        var request = input
        request.files = input.files.filter { $0.selection.getSelectionType() != .none }
        try validateSelection(request)
        if request.files.isEmpty, !request.allowEmpty {
            throw AssistedCommitError(.unsafeSelection, "Select the changes to commit.")
        }
        await options.report(.capturing)
        try cancellation.check()

        let root = try assistedRealPath(repository.path)
        let top = try await git(["rev-parse", "--show-toplevel"], root, "assistedCommitRoot")
        guard try assistedRealPath(assistedTrimLine(top.stdout)) == root else {
            throw AssistedCommitError(.unsafeSelection, "Assisted commits need the repository's top folder.")
        }
        let format = try await git(["rev-parse", "--show-ref-format"], root, "assistedCommitRefFormat")
        guard assistedTrimLine(format.stdout) == "files" else {
            throw AssistedCommitError(.unsafeSelection, "Assisted commits need a repository that stores refs as files.")
        }
        let objectFormat = try await git(["rev-parse", "--show-object-format"], root, "assistedCommitObjectFormat")
        let gitDirectory = try await assistedGitDirectory(root)
        let head = try await assistedReadHead(root, gitDirectory: gitDirectory)
        let headBytes = try assistedReadFile(POSIXPath.join(gitDirectory, "HEAD")) ?? Data()
        let indexPath = try await assistedGitPath(root, "index")
        let identity = AssistedRepositoryIdentity(
            repository: repository,
            root: root,
            gitDirectory: gitDirectory,
            indexPath: indexPath,
            originalIndex: try assistedReadIndexState(indexPath),
            originalHeadBytes: headBytes,
            originalHead: head,
            zeroID: String(repeating: "0", count: assistedTrimLine(objectFormat.stdout) == "sha256" ? 64 : 40)
        )
        try await assistedEnsureNoRepositoryOperation(identity)

        let privateRepository = try await AssistedPrivateRepository.make(for: identity)
        do {
            let snapshotID = UUID().uuidString.lowercased()
            let frozen = try await freeze(request, identity, privateRepository, cancellation)
            try await assistedVerifyHead(identity, head.sha)
            try assistedVerifyIndex(identity)
            try assistedVerifySelectedFiles(root, frozen.files)
            try await assistedEnsureNoRepositoryOperation(identity)
            try cancellation.check()
            return AssistedCommitSnapshot(
                id: snapshotID,
                analysis: AssistedCommitAnalysis(snapshotID: snapshotID, changes: frozen.changes),
                identity: identity,
                request: request,
                files: frozen.files,
                baseTree: frozen.baseTree,
                selectedTree: frozen.selectedTree,
                privateRepository: privateRepository
            )
        } catch {
            let failure = error
            do {
                try assistedRemoveOwnedDirectory(privateRepository.directory, identity: privateRepository.identity)
            } catch {
                throw AssistedCommitError(
                    .cleanupFailed,
                    "Espalier couldn't remove its temporary files after the capture failed.",
                    underlying: failure
                )
            }
            throw failure
        }
    }

    /// Throws `unsafeSelection` for selections assisted commits can't
    /// represent.
    private static func validateSelection(_ request: AssistedCommitRequest) throws {
        var paths = Set<ExactString>()
        for file in request.files {
            try assistedValidatePath(file.path)
            guard paths.insert(ExactString(file.path)).inserted else {
                throw AssistedCommitError(.unsafeSelection, "\u{201C}\(file.path)\u{201D} is selected twice.")
            }
            if let oldPath = file.status.oldPath {
                try assistedValidatePath(oldPath)
                if JSCompat.strictEquals(oldPath, file.path) {
                    throw AssistedCommitError(.unsafeSelection, "\u{201C}\(file.path)\u{201D} is renamed to itself.")
                }
            }
            if file.status.kind == .conflicted {
                throw AssistedCommitError(.unsafeSelection, "Resolve the conflicts in \u{201C}\(file.path)\u{201D} first.")
            }
            if file.status.submoduleStatus != nil {
                throw AssistedCommitError(.unsafeSelection, "Assisted commits don't include submodules. Commit \u{201C}\(file.path)\u{201D} on its own.")
            }
        }
        var renamedSources = Set<ExactString>()
        for file in request.files {
            guard case .renamed(let oldPath, _, _) = file.status else {
                continue
            }
            if paths.contains(ExactString(oldPath)) || !renamedSources.insert(ExactString(oldPath)).inserted {
                throw AssistedCommitError(.unsafeSelection, "Renames that overlap can't be committed separately.")
            }
        }
    }

    private struct Frozen {
        let baseTree: String
        let selectedTree: String
        let files: [AssistedFrozenFile]
        let changes: [AssistedCommitChange]
    }

    private static func freeze(
        _ request: AssistedCommitRequest,
        _ identity: AssistedRepositoryIdentity,
        _ privateRepository: AssistedPrivateRepository,
        _ cancellation: AssistedCommitCancellation
    ) async throws -> Frozen {
        let root = identity.root
        let baseTree = try await privateRepository.tree(of: identity.originalHead.sha)
        let scratchIndex = POSIXPath.join(privateRepository.directory, "capture-index")

        var states: [AssistedCapturedFileState] = []
        for file in request.files {
            try cancellation.check()
            states.append(try assistedReadSelectedFile(root, file.path))
        }

        var lookup: [String] = []
        for file in request.files {
            lookup.append(file.path)
            if let oldPath = file.status.oldPath {
                lookup.append(oldPath)
            }
        }
        let baseEntries = try await privateRepository.treeEntries(baseTree, lookup)

        var present: [String] = []
        for (file, state) in zip(request.files, states) where file.status.kind != .deleted {
            switch state {
            case .file, .symlink:
                present.append(file.path)
            case .missing, .directory:
                throw AssistedCommitError(.unsafeSelection, "\u{201C}\(file.path)\u{201D} is missing or is a folder. Refresh the changes and try again.")
            }
        }
        let fullEntries = try await cleanedEntries(present, baseTree: baseTree, privateRepository, scratchIndex: scratchIndex)

        var ids = Set<String>()
        func newID() -> String {
            while true {
                let id = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
                if ids.insert(id).inserted {
                    return id
                }
            }
        }

        var files: [AssistedFrozenFile] = []
        var changes: [AssistedCommitChange] = []
        for (offset, file) in request.files.enumerated() {
            try cancellation.check()
            let state = states[offset]
            let kind = file.status.kind
            let isRenamed = kind == .renamed
            let isCopied = kind == .copied
            let isDeleted = kind == .deleted
            let oldPath = file.status.oldPath
            let isPartial = file.selection.getSelectionType() == .partial

            let base: AssistedTreeEntry?
            if isRenamed {
                guard let oldPath, let source = baseEntries[ExactString(oldPath)], baseEntries[ExactString(file.path)] == nil else {
                    throw AssistedCommitError(.unsafeSelection, "The rename of \u{201C}\(file.path)\u{201D} doesn't match HEAD. Refresh the changes and try again.")
                }
                base = source
            } else {
                if isCopied, oldPath.flatMap({ baseEntries[ExactString($0)] }) == nil {
                    throw AssistedCommitError(.unsafeSelection, "The copy at \u{201C}\(file.path)\u{201D} doesn't match HEAD. Refresh the changes and try again.")
                }
                base = baseEntries[ExactString(file.path)]
            }
            if isPartial, base != nil, kind == .new || kind == .untracked {
                throw AssistedCommitError(.unsafeSelection, "\u{201C}\(file.path)\u{201D} is in HEAD now. Refresh the changes and select its lines again.")
            }
            if isPartial, isRenamed || isCopied || base?.mode == "120000" {
                throw AssistedCommitError(.unsafeSelection, "Select all of \u{201C}\(file.path)\u{201D}: part of a rename, copy, or symbolic link can't be committed.")
            }

            var full: AssistedTreeEntry?
            if !isDeleted {
                guard let entry = fullEntries[ExactString(file.path)], entry.mode != "160000" else {
                    throw AssistedCommitError(.unsafeSelection, "Espalier couldn't read \u{201C}\(file.path)\u{201D}.")
                }
                full = entry
            }

            let blocking: [(path: String, entry: AssistedTreeEntry?)] = request.files
                .filter { $0.status.kind == .deleted && JSCompat.startsWith(file.path, "\($0.path)/") }
                .map { (path: $0.path, entry: nil) }
            let shape = AssistedFrozenFile(change: file, state: state, base: base, selected: full, baseBytes: Data(), atomicID: nil, hunks: [])
            let fullTree = try await privateRepository.writeTree(baseTree, blocking + shape.treeUpdates(), indexPath: scratchIndex)

            var baseBytes = Data()
            if base != nil {
                baseBytes = try await getBlobContents(identity.repository, baseTree, isRenamed ? oldPath ?? file.path : file.path)
            }
            var fullBytes = Data()
            if full != nil {
                fullBytes = try await getBlobContents(identity.repository, fullTree, file.path)
            }
            let diffPaths = isRenamed || isCopied ? [file.path] + (oldPath.map { [$0] } ?? []) : [file.path]
            let isSymbolicLink = base?.mode == "120000" || full?.mode == "120000"
            let isLarge = baseBytes.count + fullBytes.count > assistedMaximumSplittableBytes
            let diff: (text: String, parsed: RawDiff?)
            if isLarge {
                diff = ("Selected change to \u{201C}\(file.path)\u{201D}, too large to show.\n", nil)
            } else {
                diff = try await frozenDiff(privateRepository, baseTree, fullTree, diffPaths, parse: !isSymbolicLink)
            }
            let isText = isUTF8Text(baseBytes) && isUTF8Text(fullBytes) && diff.parsed.map { !$0.isBinary } == true
            let isModeChange = base != nil && full != nil && base?.mode != full?.mode

            if isPartial, !isText || isModeChange || isSymbolicLink {
                throw AssistedCommitError(.unsafeSelection, "Select all of \u{201C}\(file.path)\u{201D}: part of a binary, very large, or mode change can't be committed.")
            }

            var selected = full
            var selectedDiff = diff
            var selectedTree = fullTree
            if isPartial {
                if await isTextConverted(identity.repository, file.path) {
                    throw AssistedCommitError(.unsafeSelection, textConvertedMessage(file.path, "committed"))
                }
                guard let parsed = diff.parsed else {
                    throw AssistedCommitError(.unsafeSelection, "Espalier couldn't read the changes to \u{201C}\(file.path)\u{201D}.")
                }
                let selection = file.selection.carried(to: parsed.hunks, selectableLines: includeableLineIndexes(parsed.hunks))
                let bytes = try selectedText(baseBytes, parsed, selection, path: file.path)
                selected = AssistedTreeEntry(
                    path: file.path,
                    mode: base?.mode ?? full?.mode ?? "100644",
                    sha: try await privateRepository.hashBlob(bytes)
                )
                selectedTree = try await privateRepository.writeTree(baseTree, blocking + shape.treeUpdates(selected), indexPath: scratchIndex)
                selectedDiff = try await frozenDiff(privateRepository, baseTree, selectedTree, diffPaths, parse: true)
            }

            if selectedTree == baseTree {
                // Cleaned, the file is HEAD's: there's nothing of it to commit.
                files.append(AssistedFrozenFile(change: file, state: state, base: base, selected: selected, baseBytes: baseBytes, atomicID: nil, hunks: []))
                continue
            }

            let isAtomic = isRenamed || isCopied || (isDeleted && !isPartial) || isModeChange || isSymbolicLink
                || selected?.mode == "120000" || !isText || (selectedDiff.parsed?.hunks.isEmpty ?? true)
            var atomicID: String?
            var hunks: [AssistedFrozenHunk] = []
            if isAtomic {
                let id = newID()
                atomicID = id
                changes.append(AssistedCommitChange(
                    id: id,
                    kind: .atomic,
                    path: file.path,
                    oldPath: isRenamed || isCopied ? oldPath : nil,
                    diff: selectedDiff.text
                ))
            } else if let parsed = selectedDiff.parsed {
                for hunk in parsed.hunks {
                    let id = newID()
                    let start = hunk.header.oldLineCount == 0 ? hunk.header.oldStartLine : hunk.header.oldStartLine - 1
                    var replacement = Data()
                    var text = ""
                    for line in hunk.lines {
                        if line.type == .context || line.type == .add {
                            replacement.append(lineBytes(line))
                        }
                        text += line.text + "\n" + (line.noTrailingNewLine ? "\\ No newline at end of file\n" : "")
                    }
                    hunks.append(AssistedFrozenHunk(id: id, start: start, end: start + hunk.header.oldLineCount, replacement: replacement))
                    changes.append(AssistedCommitChange(id: id, kind: .textHunk, path: file.path, oldPath: nil, diff: "\(parsed.header)\n\(text)"))
                }
            }
            files.append(AssistedFrozenFile(
                change: file,
                state: state,
                base: base,
                selected: selected,
                baseBytes: baseBytes,
                atomicID: atomicID,
                hunks: hunks
            ))
        }

        if changes.isEmpty, !request.allowEmpty {
            throw AssistedCommitError(.unsafeSelection, "The selected files have no changes to commit.")
        }
        let selectedTree = try await privateRepository.writeTree(baseTree, files.flatMap { $0.treeUpdates() }, indexPath: scratchIndex)
        return Frozen(baseTree: baseTree, selectedTree: selectedTree, files: files, changes: changes)
    }

    /// The entries `git update-index --add` makes for `paths` in an index
    /// seeded from `baseTree`: the files cleaned as an ordinary commit
    /// stages them (filters, line endings, modes, symbolic links).
    private static func cleanedEntries(
        _ paths: [String],
        baseTree: String,
        _ privateRepository: AssistedPrivateRepository,
        scratchIndex: String
    ) async throws -> [ExactString: AssistedTreeEntry] {
        guard !paths.isEmpty else {
            return [:]
        }
        let env: [String: String?] = ["GIT_INDEX_FILE": scratchIndex]
        try await privateRepository.readTree(baseTree, into: scratchIndex)
        var stdin = Data()
        for path in paths {
            stdin.append(Data(path.utf8))
            stdin.append(0)
        }
        try await privateRepository.run(
            privateRepository.noHooks + ["update-index", "--add", "--remove", "--replace", "-z", "--stdin"],
            "assistedCommitCleanSelectedFiles",
            env: env,
            stdin: stdin
        )
        let listed = try await privateRepository.run(
            privateRepository.noHooks + ["ls-files", "--stage", "-z", "--"] + literalPathspecs(paths),
            "assistedCommitReadCleanedFiles",
            env: env
        )
        var entries: [ExactString: AssistedTreeEntry] = [:]
        for record in listed.stdoutData.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else {
                continue
            }
            let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            guard fields.count == 3 else {
                continue
            }
            entries[ExactString(path)] = AssistedTreeEntry(path: path, mode: String(fields[0]), sha: String(fields[1]))
        }
        return entries
    }

    /// The diff of `paths` between two trees, without external diff
    /// programs, textconv, or rename detection, parsed when it's one path's
    /// UTF-8 text.
    private static func frozenDiff(
        _ privateRepository: AssistedPrivateRepository,
        _ from: String,
        _ to: String,
        _ paths: [String],
        parse: Bool
    ) async throws -> (text: String, parsed: RawDiff?) {
        let result = try await privateRepository.run(
            [
                "-c", "diff.suppressBlankEmpty=false",
                "-c", "diff.noprefix=false",
                "-c", "diff.mnemonicPrefix=false",
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--patch",
                "--src-prefix=a/", "--dst-prefix=b/",
                "--end-of-options", from, to, "--",
            ] + literalPathspecs(paths),
            "assistedCommitFrozenDiff"
        )
        let text = String(decoding: result.stdoutData, as: UTF8.self)
        guard parse, paths.count == 1, Data(text.utf8) == result.stdoutData else {
            return (text, nil)
        }
        return (text, try DiffParser().parse(text))
    }

    /// HEAD's bytes with the selected lines of `diff` applied: context and
    /// unselected deletions kept, selected additions added.
    static func selectedText(_ baseBytes: Data, _ diff: RawDiff, _ selection: DiffSelection, path: String) throws -> Data {
        let mismatch = AssistedCommitError(.unsafeSelection, "The selected lines of \u{201C}\(path)\u{201D} don't match the file. Refresh the changes and select them again.")
        let base = assistedSplitLines(baseBytes)
        var result = Data()
        func append(_ bytes: Data) throws {
            guard !bytes.isEmpty else {
                return
            }
            if let last = result.last, last != UInt8(ascii: "\n") {
                // A line without its newline would join the next one.
                throw AssistedCommitError(.unsafeSelection, "Select all of the change to the last line of \u{201C}\(path)\u{201D}, or none of it.")
            }
            result.append(bytes)
        }
        var cursor = 0
        var selectedLines = 0
        for hunk in diff.hunks {
            let start = hunk.header.oldLineCount == 0 ? hunk.header.oldStartLine : hunk.header.oldStartLine - 1
            guard start >= cursor, start <= base.count else {
                throw mismatch
            }
            for line in base[cursor..<start] {
                try append(line)
            }
            cursor = start
            for (index, line) in hunk.lines.enumerated() where line.type != .hunk {
                let bytes = lineBytes(line)
                if line.type != .add {
                    guard cursor < base.count, base[cursor] == bytes else {
                        throw mismatch
                    }
                    cursor += 1
                }
                let isSelected = selection.isSelected(hunk.unifiedDiffStart + index)
                if line.type == .context || (line.type == .delete && !isSelected) || (line.type == .add && isSelected) {
                    try append(bytes)
                }
                if line.type != .context, isSelected {
                    selectedLines += 1
                }
            }
            guard cursor == start + hunk.header.oldLineCount else {
                throw mismatch
            }
        }
        guard selectedLines > 0 else {
            throw AssistedCommitError(.unsafeSelection, "None of the selected lines of \u{201C}\(path)\u{201D} are changes. Refresh the changes and select them again.")
        }
        for line in base[cursor...] {
            try append(line)
        }
        return result
    }

    // MARK: Plans

    /// One commit of the whole selection, with a message that describes all
    /// of it: for a planner that couldn't tell the boundaries, a split that
    /// can't be committed in order (`unsafePlan`), or an empty commit.
    /// Validate it like any plan.
    ///
    /// - Throws: `invalidPlan` when `reason` is `emptySelection` and there
    ///   are units, or isn't and there are none.
    public func singleCommitPlan(
        reason: AssistedCommitSingleCommitReason,
        title: String,
        description: String? = nil
    ) throws -> AssistedCommitPlan {
        guard (reason == .emptySelection) == analysis.changes.isEmpty else {
            throw AssistedCommitError(.invalidPlan, "The reason for one commit doesn't match the selection.")
        }
        let plan = AssistedCommitPlan(
            snapshotID: id,
            commits: [AssistedCommitPlanCommit(title: title, description: description, changeIDs: analysis.changes.map(\.id))]
        )
        try checkShape(plan)
        return plan
    }

    /// Throws `invalidPlan` unless `plan` names this snapshot and its
    /// commits have one-line, non-blank titles, descriptions without NUL,
    /// and own every unit exactly once, none empty.
    func checkShape(_ plan: AssistedCommitPlan) throws {
        func invalid(_ message: String) -> AssistedCommitError {
            AssistedCommitError(.invalidPlan, message)
        }
        guard JSCompat.strictEquals(plan.snapshotID, id) else {
            throw invalid("The plan is for other changes.")
        }
        guard !plan.commits.isEmpty else {
            throw invalid("The plan has no commits.")
        }
        let known = Set(analysis.changes.map(\.id).map(ExactString.init))
        let isEmptySelection = known.isEmpty && request.allowEmpty
        var owned = Set<ExactString>()
        for commit in plan.commits {
            guard !commit.title.unicodeScalars.allSatisfy(JSCompat.isWhitespace),
                  !commit.title.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
            else {
                throw invalid("Every commit needs a title of one line.")
            }
            if let description = commit.description, description.unicodeScalars.contains("\0") {
                throw invalid("A commit description can't contain NUL.")
            }
            if commit.changeIDs.isEmpty, !(isEmptySelection && plan.commits.count == 1) {
                throw invalid("A commit in the plan has no changes.")
            }
            for changeID in commit.changeIDs {
                let id = ExactString(changeID)
                guard known.contains(id) else {
                    throw invalid("The plan names a change that isn't selected.")
                }
                guard owned.insert(id).inserted else {
                    throw invalid("The plan puts a change in more than one commit.")
                }
            }
        }
        guard owned.count == known.count else {
            throw invalid("The plan leaves out some of the selected changes.")
        }
    }

    /// Checks `plan` and makes every cumulative tree from HEAD's, before
    /// anything is committed: each commit must change the tree, and the last
    /// tree must be exactly the selected changes' tree.
    ///
    /// - Throws: `invalidPlan` for the wrong shape (never a reason to fall
    ///   back); `unsafePlan` when a well-formed split can't be committed in
    ///   its order (`singleCommitPlan(reason: .unsafeSplit, ...)` may follow);
    ///   `selectionChanged`, `repositoryChanged`, `indexChanged`,
    ///   `cancelled`; `busy` and `disposed`.
    public func validate(_ plan: AssistedCommitPlan, options: AssistedCommitOptions = AssistedCommitOptions()) async throws -> ValidatedAssistedCommitPlan {
        try await assistedShielded(options.cancellation) {
            try await self.validateUnshielded(plan, options)
        }
    }

    private func validateUnshielded(_ plan: AssistedCommitPlan, _ options: AssistedCommitOptions) async throws -> ValidatedAssistedCommitPlan {
        let cancellation = options.cancellation
        try cancellation.check()
        try requirePhase(.captured)
        try checkShape(plan)
        phase = .validating
        defer {
            if phase == .validating {
                phase = .captured
            }
        }
        await options.report(.validating)
        let identity = identity
        try await assistedVerifyHead(identity, originalHead.sha)
        try assistedVerifyIndex(identity)
        try assistedVerifySelectedFiles(identity.root, files)

        let isEmptySelection = analysis.changes.isEmpty && request.allowEmpty
        var trees: [String] = []
        var included = Set<String>()
        var previous = baseTree
        for (index, commit) in plan.commits.enumerated() {
            try cancellation.check()
            included.formUnion(commit.changeIDs)
            let tree: String
            do {
                tree = try await materializeTree(included, indexPath: POSIXPath.join(privateRepository.directory, "plan-index-\(index)"))
            } catch let error as AssistedCommitError {
                throw error
            } catch {
                throw AssistedCommitError(.unsafePlan, "The planned commits can't be made in this order.", underlying: error)
            }
            if tree == previous, !isEmptySelection {
                throw AssistedCommitError(.unsafePlan, "A planned commit doesn't change anything.")
            }
            trees.append(tree)
            previous = tree
        }
        guard previous == selectedTree else {
            throw AssistedCommitError(.unsafePlan, "The planned commits don't add up to the selected changes.")
        }

        try await assistedVerifyHead(identity, originalHead.sha)
        try assistedVerifyIndex(identity)
        try assistedVerifySelectedFiles(identity.root, files)
        try cancellation.check()
        let token = UUID()
        validatedPlans[token] = trees
        return ValidatedAssistedCommitPlan(plan: plan, trees: trees, token: token)
    }

    /// HEAD's tree with the units in `included`.
    private func materializeTree(_ included: Set<String>, indexPath: String) async throws -> String {
        // A file can't be added inside a file that's still there: its
        // deletion must come first.
        for file in files where file.selected != nil {
            let adds = file.atomicID.map(included.contains) ?? file.hunks.contains { included.contains($0.id) }
            guard adds else {
                continue
            }
            for blocker in files where blocker.selected == nil && JSCompat.startsWith(file.path, "\(blocker.path)/") {
                if let blockerID = blocker.atomicID, !included.contains(blockerID) {
                    throw AssistedCommitError(.unsafePlan, "\u{201C}\(file.path)\u{201D} can't be committed before \u{201C}\(blocker.path)\u{201D} is deleted.")
                }
            }
        }
        var entries: [(path: String, entry: AssistedTreeEntry?)] = []
        for file in files {
            if let atomicID = file.atomicID {
                if included.contains(atomicID) {
                    entries += file.treeUpdates()
                }
            } else if file.hunks.contains(where: { included.contains($0.id) }) {
                guard let selected = file.selected else {
                    throw AssistedCommitError(.unsafePlan, "Espalier lost track of \u{201C}\(file.path)\u{201D}.")
                }
                let sha = try await privateRepository.hashBlob(try cumulativeContent(file, included))
                entries.append((path: file.path, entry: AssistedTreeEntry(path: file.path, mode: selected.mode, sha: sha)))
            }
        }
        return try await privateRepository.writeTree(baseTree, entries, indexPath: indexPath)
    }

    /// HEAD's bytes of `file` with its hunks in `included`.
    private func cumulativeContent(_ file: AssistedFrozenFile, _ included: Set<String>) throws -> Data {
        let lines = assistedSplitLines(file.baseBytes)
        var result = Data()
        var cursor = 0
        for hunk in file.hunks where included.contains(hunk.id) {
            guard hunk.start >= cursor, hunk.end <= lines.count, hunk.start <= hunk.end else {
                throw AssistedCommitError(.unsafePlan, "The hunks of \u{201C}\(file.path)\u{201D} can't be combined.")
            }
            for line in lines[cursor..<hunk.start] {
                result.append(line)
            }
            result.append(hunk.replacement)
            cursor = hunk.end
        }
        for line in lines[cursor...] {
            result.append(line)
        }
        return result
    }

    // MARK: Disposal

    /// Removes the snapshot's temporary files. Safe to call again; a
    /// failure can be retried.
    ///
    /// - Throws: `busy` while validating or executing; `cleanupFailed`.
    public func dispose() throws {
        switch phase {
        case .disposed:
            return
        case .validating, .executing:
            throw AssistedCommitError(.busy, "The assisted commit is still running.")
        case .captured:
            break
        }
        do {
            try assistedRemoveOwnedDirectory(privateRepository.directory, identity: privateRepository.identity)
        } catch {
            throw AssistedCommitError.wrapping(error, .cleanupFailed, "Espalier couldn't remove its temporary files.")
        }
        phase = .disposed
        validatedPlans = [:]
    }

    func requirePhase(_ expected: Phase) throws {
        guard phase == expected else {
            if phase == .disposed {
                throw AssistedCommitError(.disposed, "The assisted commit's snapshot is gone.")
            }
            throw AssistedCommitError(.busy, "The assisted commit is still running.")
        }
    }
}

/// Captures a snapshot, runs `body` with it, and disposes it, whatever
/// `body` does. A disposal that fails after `body` failed keeps `body`'s
/// error, with its recovery, as the cause.
public nonisolated(nonsending) func withAssistedCommitSnapshot<T: Sendable>(
    _ repository: Repository,
    _ request: AssistedCommitRequest,
    options: AssistedCommitOptions = AssistedCommitOptions(),
    _ body: nonisolated(nonsending) (AssistedCommitSnapshot) async throws -> T
) async throws -> T {
    let snapshot = try await AssistedCommitSnapshot.capture(repository, request, options: options)
    let result: Result<T, any Error>
    do {
        result = .success(try await body(snapshot))
    } catch {
        result = .failure(error)
    }
    do {
        try await snapshot.dispose()
    } catch let cleanupError {
        if case .failure(let error) = result {
            let original = AssistedCommitError.wrapping(error, .commitFailed, "The assisted commit failed.")
            throw AssistedCommitError(
                original.recovery == nil ? .cleanupFailed : .recoveryFailed,
                original.message,
                underlying: cleanupError,
                recovery: original.recovery
            )
        }
        throw cleanupError
    }
    return try result.get()
}

/// The bytes of `line` in the file: its text without the diff's prefix,
/// with its newline unless it has none.
private func lineBytes(_ line: DiffLine) -> Data {
    var bytes = Data(line.text.utf8.dropFirst())
    if !line.noTrailingNewLine {
        bytes.append(UInt8(ascii: "\n"))
    }
    return bytes
}

/// Whether `bytes` is UTF-8 text without NUL.
private func isUTF8Text(_ bytes: Data) -> Bool {
    !bytes.contains(0) && Data(String(decoding: bytes, as: UTF8.self).utf8) == bytes
}

/// `bytes` split into lines, each with its newline (the last one may have
/// none).
func assistedSplitLines(_ bytes: Data) -> [Data] {
    var lines: [Data] = []
    var start = bytes.startIndex
    while start < bytes.endIndex {
        if let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(bytes[start...newline])
            start = newline + 1
        } else {
            lines.append(bytes[start...])
            break
        }
    }
    return lines
}

/// Throws `selectionChanged` unless every selected file is as captured.
func assistedVerifySelectedFiles(_ root: String, _ files: [AssistedFrozenFile]) throws {
    for file in files {
        guard try assistedReadSelectedFile(root, file.path) == file.state else {
            throw AssistedCommitError(.selectionChanged, "\u{201C}\(file.path)\u{201D} changed during the assisted commit.")
        }
    }
}

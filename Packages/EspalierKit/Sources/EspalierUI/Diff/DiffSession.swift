// Ported in part from desktop/app/src/ui/diff/seamless-diff-switcher.tsx
//
// What a diff view keeps between updates. When a text diff arrives it
// paints at once; the file's whole contents then load
// (`DiffContentsLoader`), which add the bottom hunk that expands the end of
// the file, enable the expansion buttons, and feed syntax highlighting,
// whose tokens arrive later still. The first paint never waits for the
// contents.

import EspalierCore
import EspalierSupport
import GitKit
import Observation
import os

private let logger = Log.logger(category: "diff")

/// A diff view's state.
@MainActor @Observable
final class DiffSession {
    /// The file the state is for.
    private(set) var fileID: String?
    /// The file of the diff last loaded (shown while the next one loads).
    private(set) var loadedFileID: String?
    /// The file change's own ID (`FileChange.id`), which the contents
    /// loader reports.
    private var changeID: String?
    /// The model's text diff the state is for.
    private(set) var source: TextDiff?
    /// Whether `source` is a large diff shown anyway (no bottom hunk).
    private(set) var sourceIsLarge = false
    /// `source` with a dummy hunk at the bottom, once the contents show the
    /// diff can expand there.
    private(set) var base: TextDiff?
    /// The diff after the user's expansions.
    private(set) var expanded: TextDiff?
    /// The file's contents, once loaded.
    private(set) var contents: DiffFileContents?
    /// Syntax tokens, and a generation bumped when they change.
    private(set) var tokens = FileTokens.none
    private(set) var tokensGeneration = 0
    /// "Show Diff" was clicked for this large diff.
    var forceShowLargeDiff = false
    /// The image diff shown, decoded once.
    private(set) var images: (diff: ImageDiff, content: ImageDiffContent)?

    @ObservationIgnored private var loader: DiffContentsLoader?
    @ObservationIgnored private weak var loaderRepository: RepositoryModel?
    @ObservationIgnored private var contentsTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var file: DiffFileInfo?
    @ObservationIgnored var highlighter: (any SyntaxHighlighter)?
    @ObservationIgnored var tabSize = 4
    @ObservationIgnored private var openInterval: (fileID: String, state: OSSignpostIntervalState, start: ContinuousClock.Instant)?

    // MARK: Updates

    /// The view shows another file: forgets the last one's state and starts
    /// the `DiffOpen` interval.
    func fileDidChange(_ file: DiffFileInfo?) {
        self.file = file
        guard file?.id != fileID else {
            return
        }
        fileID = file?.id
        changeID = file?.change?.id
        images = nil
        source = nil
        sourceIsLarge = false
        base = nil
        expanded = nil
        contents = nil
        forceShowLargeDiff = false
        clearTokens()
        contentsTask?.cancel()
        highlightTask?.cancel()
        if let fileID = file?.id {
            beginOpen(fileID)
        }
    }

    /// The model's diff changed: a new text diff resets the expansions and
    /// loads the file's contents.
    func diffDidChange(_ diff: Diff?, file: DiffFileInfo?, repository: RepositoryModel?) {
        self.file = file
        if diff != nil {
            loadedFileID = fileID
        }
        let text: TextDiff?
        var isLarge = false
        switch diff {
        case .text(let textDiff)?:
            text = textDiff
        case .largeText(let large)?:
            text = TextDiff(large)
            isLarge = true
        default:
            text = nil
        }
        if case .image(let imageDiff)? = diff {
            if images?.diff != imageDiff {
                images = (imageDiff, ImageDiffContent(imageDiff))
            }
        } else if images != nil {
            images = nil
        }
        guard let text else {
            if source != nil {
                source = nil
                base = nil
                expanded = nil
                clearTokens()
            }
            if diff != nil, let fileID {
                // Non-text diffs paint in the frame they arrive in.
                didPaint(fileID)
            }
            return
        }
        if let source, sourceIsLarge == isLarge, textDiffEquals(source, text) {
            return
        }
        source = text
        sourceIsLarge = isLarge
        base = nil
        expanded = nil
        clearTokens()
        if let contents, contents.fileID == changeID {
            // The same file changed: keep its contents until they reload.
            applyContents(contents)
        }
        loadContents(file: file, repository: repository)
    }

    /// The diff to show for the model's `diff`: the expanded or bottom-hunk
    /// version when this state is for it, else the diff itself.
    func displayDiff(for diff: TextDiff, isLarge: Bool) -> TextDiff {
        guard let source, sourceIsLarge == isLarge, textDiffEquals(source, diff) else {
            return diff
        }
        return expanded ?? base ?? source
    }

    /// Whether the diff can expand: the contents are loaded, small enough,
    /// and not empty.
    func canExpand(_ diff: TextDiff, isLarge: Bool) -> Bool {
        guard let source, sourceIsLarge == isLarge, textDiffEquals(source, diff),
              let contents, contents.fileID == changeID
        else {
            return false
        }
        return contents.canBeExpanded && !contents.newLines.isEmpty
    }

    /// Whether lines were expanded ("Collapse Expanded Lines").
    var hasExpandedLines: Bool {
        expanded != nil
    }

    // MARK: Contents

    private func loadContents(file: DiffFileInfo?, repository: RepositoryModel?) {
        contentsTask?.cancel()
        guard let file, let change = file.change, let repository else {
            return
        }
        if loader == nil || loaderRepository !== repository {
            loader = DiffContentsLoader(repository: repository)
            loaderRepository = repository
        }
        guard let loader else {
            return
        }
        switch change {
        case .committed(let committed):
            loader.load(committed)
        case .workingDirectory(let working):
            loader.load(working)
        }
        let fileID = file.id
        let changeID = change.id
        contentsTask = Task { [weak self, loader] in
            await loader.idle()
            guard !Task.isCancelled, let self, self.fileID == fileID,
                  let contents = loader.contents.value, contents.fileID == changeID
            else {
                return
            }
            self.applyContents(contents)
        }
    }

    /// Applies loaded contents: the bottom hunk, when the diff can expand,
    /// then highlighting.
    func applyContents(_ contents: DiffFileContents) {
        guard contents.fileID == changeID, let source else {
            return
        }
        self.contents = contents
        if !sourceIsLarge, contents.canBeExpanded {
            base = getTextDiffWithBottomDummyHunk(source, source.hunks, contents.oldLines.count, contents.newLines.count)
        } else {
            base = nil
        }
        highlight()
    }

    // MARK: Expansion

    /// Expands a hunk up or down.
    func expandHunk(_ hunkIndex: Int, _ kind: DiffExpansionKind) {
        guard let contents, let current = expanded ?? base ?? source,
              let updated = expandTextDiffHunk(current, hunkIndex: hunkIndex, kind, contents.newLines)
        else {
            return
        }
        expanded = updated
        highlight()
    }

    /// Expands the whole file.
    func expandWholeFile() {
        guard let contents, let current = expanded ?? base ?? source,
              let updated = expandWholeTextDiff(current, contents.newLines)
        else {
            return
        }
        expanded = updated
        highlight()
    }

    /// Collapses every expanded line, back to the diff as loaded.
    func collapseExpandedLines() {
        expanded = nil
    }

    // MARK: Highlighting

    private func clearTokens() {
        highlightTask?.cancel()
        if !tokens.isEmpty {
            tokens = .none
            tokensGeneration &+= 1
        }
    }

    /// Highlights the file's old and new contents off the main actor, for
    /// the lines the diff shows, and applies the tokens if the diff is still
    /// the same.
    private func highlight() {
        highlightTask?.cancel()
        guard let highlighter, let contents, let file, let diff = expanded ?? base ?? source, !contents.isBinary else {
            return
        }
        let fileID = fileID
        let source = source
        let tabSize = tabSize
        let path = file.path
        let oldPath = file.oldPath ?? file.path
        highlightTask = Task { [weak self] in
            let tokens = await highlightContents(contents, path: path, oldPath: oldPath, hunks: diff.hunks, tabSize: tabSize, highlighter: highlighter)
            guard !Task.isCancelled, let self, self.fileID == fileID,
                  let current = self.source, let source, textDiffEquals(current, source)
            else {
                return
            }
            if tokens != self.tokens {
                self.tokens = tokens
                self.tokensGeneration &+= 1
            }
        }
    }

    /// Waits for the contents and tokens in flight (tests).
    func idle() async {
        await contentsTask?.value
        await highlightTask?.value
    }

    // MARK: The DiffOpen interval

    private func beginOpen(_ fileID: String) {
        if let openInterval {
            UISignposts.end(.diffOpen, openInterval.state)
        }
        openInterval = (fileID, UISignposts.begin(.diffOpen), ContinuousClock.now)
    }

    /// The file's diff painted: ends the `DiffOpen` interval.
    func didPaint(_ fileID: String) {
        guard let openInterval, openInterval.fileID == fileID else {
            return
        }
        UISignposts.end(.diffOpen, openInterval.state)
        DiffOpenProbe.shared.record(fileID: fileID, duration: ContinuousClock.now - openInterval.start)
        self.openInterval = nil
    }
}

/// Compares two text diffs for structural equality: the text, warnings,
/// and hunk count, then only the last hunk, which is the only place equal
/// text can still differ (a missing newline at the end).
nonisolated func textDiffEquals(_ x: TextDiff, _ y: TextDiff) -> Bool {
    guard x.text == y.text,
          x.hasHiddenBidiChars == y.hasHiddenBidiChars,
          x.lineEndingsChange == y.lineEndingsChange,
          x.hunks.count == y.hunks.count
    else {
        return false
    }
    // This is a performance optimization which lets us avoid iterating over all
    // lines (deep equality on all hunks). We're already comparing the diff text
    // above so the only thing that can change with the diff text staying the
    // same is whether or not the last line is followed by a trailing newline.
    return x.hunks.isEmpty || x.hunks[x.hunks.count - 1] == y.hunks[y.hunks.count - 1]
}

/// Click-to-paint times of diffs, for the Debug menu's Diff Open Benchmark
/// and the performance tests.
@MainActor
final class DiffOpenProbe {
    static let shared = DiffOpenProbe()

    /// The latest durations, newest last.
    private(set) var durations: [(fileID: String, duration: Duration)] = []
    private var waiters: [String: [CheckedContinuation<Duration, Never>]] = [:]

    func record(fileID: String, duration: Duration) {
        durations.append((fileID, duration))
        if durations.count > 200 {
            durations.removeFirst(durations.count - 200)
        }
        for waiter in waiters.removeValue(forKey: fileID) ?? [] {
            waiter.resume(returning: duration)
        }
    }

    /// Waits for a file's diff to paint, returning its click-to-paint time.
    func waitForPaint(of fileID: String) async -> Duration {
        await withCheckedContinuation { continuation in
            waiters[fileID, default: []].append(continuation)
        }
    }

    /// Stops waiting for a file (it never painted).
    func cancelWait(for fileID: String) {
        for waiter in waiters.removeValue(forKey: fileID) ?? [] {
            waiter.resume(returning: .zero)
        }
    }
}

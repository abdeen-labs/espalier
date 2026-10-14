// The diff container's layouts: the header, the previous file's diff while
// the next loads, a text diff with its warnings and with find open, the find
// bar's states, a large diff, a binary file, a submodule's change, a failed
// diff, empty states, the image modes with their picker, an image that
// can't be decoded, a conflicted image, and a working directory file of a
// real repository with its staging gutter, contents, and syntax color. A
// text diff, find, the loading header, the binary file, the two-up image,
// and the image states in light and dark, the rest in light.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff container", .captures, .hangGuard(minutes: 5), .offline) @MainActor
struct DiffContainerCaptures {
    private let area = "Diff"
    private static let size = CGSize(width: 640, height: 300)

    /// Captures a view without a diff table at `size`.
    private func capture(_ view: some View, named name: String, size: CGSize = Self.size, appearances: [CaptureAppearance] = [.light]) {
        EspalierCaptures.capture(view.frame(width: size.width, height: size.height), named: name, area: area, size: size, appearances: appearances)
    }

    private var modified: DiffFileInfo {
        DiffFileInfo(DiffCaptureFixtures.workingFile("Sources/App/RepositoryLoader.swift"))
    }

    // MARK: Text

    @Test("a text diff with its header")
    func textDiff() async {
        await captureDiffView(
            { DiffContainer(.loaded(.text(DiffCaptureFixtures.swiftChange)), file: modified, context: .history) },
            named: "container-text",
            area: area,
            size: Self.size,
            appearances: CaptureAppearance.allCases
        )
    }

    @Test("the next file's header over the previous file's diff while the next loads: no counts")
    func loadingNext() async {
        await captureDiffView(
            {
                DiffContainer(
                    .loading(previous: .text(DiffCaptureFixtures.swiftChange)),
                    file: DiffFileInfo(path: "Sources/App/EmptyState.swift", status: .modified),
                    context: .history
                )
            },
            named: "container-loading-next",
            area: area,
            size: Self.size,
            appearances: CaptureAppearance.allCases
        )
    }

    @Test("warnings above a text diff")
    func warnings() async {
        let diff = DiffCaptureFixtures.swiftChange
        let warned = TextDiff(
            text: diff.text,
            hunks: diff.hunks,
            lineEndingsChange: LineEndingsChange(from: .crlf, to: .lf),
            maxLineNumber: diff.maxLineNumber,
            hasHiddenBidiChars: true
        )
        await captureDiffView(
            { DiffContainer(.loaded(.text(warned)), file: modified, context: .history) },
            named: "container-warnings",
            area: area,
            size: CGSize(width: 640, height: 360)
        )
    }

    // MARK: Find

    /// Find open on the Swift change from its first added line, searching
    /// for `query`.
    private func find(_ query: String) -> DiffFindModel {
        let find = DiffFindModel()
        find.documentDidChange(DiffDocument(input: DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange).documentInput), isNewFile: true)
        find.show(focus: false, from: DiffFindPosition(row: 5, column: .before, offset: 0))
        find.query = query
        return find
    }

    @Test("the find bar: empty, counting matches, and finding none", arguments: [
        NamedCase("find-bar-empty", ""),
        NamedCase("find-bar-matches", "tip"),
        NamedCase("find-bar-no-matches", "tipx"),
    ])
    func findBar(_ query: NamedCase<String>) {
        EspalierCaptures.capture(
            DiffFindBar(find: find(query.value)).frame(maxWidth: .infinity, maxHeight: .infinity),
            named: query.name,
            area: area,
            size: CGSize(width: 420, height: 90)
        )
    }

    @Test("a text diff with find open over its top trailing corner")
    func containerFind() async {
        await captureDiffView(
            { DiffContainer(.loaded(.text(DiffCaptureFixtures.swiftChange)), file: modified, context: .history) },
            named: "container-find",
            area: area,
            size: Self.size,
            appearances: CaptureAppearance.allCases,
            prepare: { _, controller in
                controller.find.show(focus: false, from: .start)
                controller.find.query = "path"
            }
        )
    }

    // MARK: States

    @Test("a large diff")
    func largeDiff() {
        let diff = DiffCaptureFixtures.swiftChange
        let large = LargeTextDiff(text: diff.text, hunks: diff.hunks, maxLineNumber: diff.maxLineNumber, hasHiddenBidiChars: false)
        capture(DiffContainer(.loaded(.largeText(large)), file: modified, context: .history), named: "container-large")
    }

    @Test("a binary file: Open with Default App in Changes, nothing to open elsewhere", arguments: [
        NamedCase("binary-changes", true),
        NamedCase("binary-history", false),
    ])
    func binary(_ opens: NamedCase<Bool>) {
        capture(BinaryDiffView(open: opens.value ? {} : nil), named: opens.name, size: CGSize(width: 480, height: 200), appearances: CaptureAppearance.allCases)
    }

    @Test("a submodule's change")
    func submodule() {
        let changed = SubmoduleDiff(
            fullPath: "/Users/joe/Developer/espalier/Vendor/lib", path: "Vendor/lib", url: "https://github.com/joe/lib.git",
            status: SubmoduleStatus(commitChanged: true, modifiedChanges: true, untrackedChanges: true),
            oldSHA: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", newSHA: "0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"
        )
        capture(
            SubmoduleDiffView(content: SubmoduleDiffContent(diff: changed, readOnly: false), openSubmodule: {}),
            named: "submodule-changed",
            size: CGSize(width: 560, height: 360)
        )
    }

    @Test("a text diff with no hunks: whitespace changes hidden")
    func noHunks() {
        capture(NoHunksView(status: .modified(), hidesWhitespace: true), named: "empty-whitespace", size: CGSize(width: 480, height: 200))
    }

    @Test("a text diff with no hunks: a rename with changes")
    func renamedWithChanges() {
        capture(
            NoHunksView(status: .renamed(oldPath: "Sources/Old.swift", renameIncludesModifications: true), hidesWhitespace: false),
            named: "empty-renamed",
            size: CGSize(width: 480, height: 200)
        )
    }

    @Test("a failed diff")
    func failed() {
        let error = OperationError(.other("Could not read the file."), operation: .loadDiff)
        capture(DiffContainer(.failed(error), file: modified, context: .history), named: "container-failed", size: CGSize(width: 480, height: 240))
    }

    // MARK: Images

    @Test("image diffs: the four modes", arguments: ImageDiffType.allModes)
    func images(_ mode: ImageDiffType) {
        capture(
            ImageDiffView(diff: DiffCaptureImages.modified, status: .modified, mode: mode),
            named: "image-\(mode)",
            size: CGSize(width: 560, height: 300),
            appearances: mode == .twoUp ? CaptureAppearance.allCases : [.light]
        )
    }

    @Test("an image that can't be decoded: added alone, and beside the old one in 2-Up")
    func undecodableImage() {
        let broken = DiffCaptureImages.image(Data("not an image".utf8))
        capture(
            ImageDiffView(diff: ImageDiff(current: broken), status: .new, mode: .twoUp),
            named: "image-undecodable",
            size: CGSize(width: 560, height: 300),
            appearances: CaptureAppearance.allCases
        )
        capture(
            ImageDiffView(diff: ImageDiff(previous: DiffCaptureImages.previous, current: broken), status: .modified, mode: .twoUp),
            named: "image-undecodable-twoUp",
            size: CGSize(width: 560, height: 300),
            appearances: CaptureAppearance.allCases
        )
    }

    @Test("a conflicted image: a side to choose, a side chosen, and none to choose (a stash restore)", arguments: [
        NamedCase(
            "image-conflicted",
            ConflictFileRowContent(
                path: "Assets/icon.png", state: .manual, status: "Manual conflict",
                oursLabel: "Use the modified file from main", theirsLabel: "Use the modified file from feature"
            )
        ),
        NamedCase(
            "image-conflicted-chosen",
            ConflictFileRowContent(path: "Assets/icon.png", state: .resolved(isUndoable: true), status: "Using the modified file from main")
        ),
        NamedCase("image-conflicted-restore", ConflictFileRowContent(path: "Assets/icon.png", state: .manual, status: "Manual conflict")),
    ])
    func conflictedImage(_ row: NamedCase<ConflictFileRowContent>) {
        capture(
            ImageDiffView(diff: ImageDiff(), status: .conflicted, conflict: row.value, mode: .twoUp),
            named: row.name,
            size: CGSize(width: 560, height: 240),
            appearances: CaptureAppearance.allCases
        )
    }

    @Test("an image diff shows its mode picker above the images")
    func imageHeader() {
        let file = DiffFileInfo(path: "Assets/icon.png", status: .modified)
        capture(
            DiffContainer(.loaded(.image(DiffCaptureImages.modified)), file: file, context: .history),
            named: "container-image",
            size: CGSize(width: 640, height: 320)
        )
    }

    // MARK: A repository's file

    /// Writes a PNG of `color` to icon.png and commits it.
    private static func commitIcon(_ color: NSColor, _ message: String, in local: Repository) async throws {
        let png = DiffCaptureImages.png(width: 120, height: 90, color: color, inset: 10)
        try png.write(to: URL(exactFilePath: POSIXPath.join(local.path, "icon.png")))
        try await runGit(["add", "icon.png"], local)
        try await runGit(["commit", "-m", message], local)
    }

    @Test("an image conflicted by a merge, changed in the working directory, in a window: how to resolve it")
    func conflictedImageInMerge() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try setupEmptyRepository()
            try await Self.commitIcon(.systemBlue, "Add the icon", in: local)
            try await runGit(["branch", "feature"], local)
            try await Self.commitIcon(.systemOrange, "Make the icon orange", in: local)
            try await runGit(["checkout", "feature"], local)
            try await Self.commitIcon(.systemGreen, "Make the icon green", in: local)
            _ = try await Dugite.exec(["merge", "master"], local.path)
            // Git leaves the branch's version, which has no diff; another
            // one makes the diff an image diff.
            try DiffCaptureImages.png(width: 120, height: 90, color: .systemPurple, inset: 10)
                .write(to: URL(exactFilePath: POSIXPath.join(local.path, "icon.png")))
            let fixture = try await ChangesCaptureRepository.make(local)
            let changes = fixture.repository.changes
            let file = try #require(changes.workingDirectory.files.first { $0.path == "icon.png" })
            changes.select(fileIDs: [file.id])
            await changes.diffIdle()
            capture(
                DiffContainer(changes.diff, file: DiffFileInfo(file), context: .conflict).windowEnvironment(fixture.context),
                named: "container-image-conflicted",
                size: CGSize(width: 640, height: 300),
                appearances: CaptureAppearance.allCases
            )
            await fixture.app.idle()
        }
    }

    /// Numbers.swift's lines: `let lineN = N`, with `replacing`'s in their
    /// places.
    private static func numbered(_ count: Int, replacing: [Int: String] = [:]) -> String {
        (1...count).map { replacing[$0] ?? "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test("a working directory file in a window: the header, the staging gutter, the bottom hunk, and syntax color")
    func changes() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let local = try setupEmptyRepository()
            try harness.write("Numbers.swift", Self.numbered(30), in: local)
            try await runGit(["add", "Numbers.swift"], local)
            try await runGit(["commit", "-m", "Number the lines"], local)
            try harness.write("Numbers.swift", Self.numbered(30, replacing: [2: "let two = 2 // two", 15: "let fifteen = \"15\""]), in: local)
            let repository = try await harness.addAndSelect(local, to: app)
            await repository.refresh(reason: .user)
            let changes = repository.changes
            let file = try #require(changes.workingDirectory.files.first { $0.path == "Numbers.swift" })
            changes.select(fileIDs: [file.id])
            await changes.diffIdle()
            guard case .loaded(.text) = changes.diff else {
                Issue.record("No text diff: \(changes.diff)")
                return
            }
            let context = WindowContext(app: app)
            await captureDiffView(
                {
                    DiffContainer(changes.diff, file: DiffFileInfo(file), context: .changes, staging: DiffStaging(changes: changes))
                        .environment(\.syntaxHighlighter, TreeSitterHighlighter())
                        .windowEnvironment(context)
                },
                named: "container-changes",
                area: area,
                size: CGSize(width: 640, height: 420),
                // The file's contents add the bottom hunk; its tokens
                // follow.
                ready: { controller in
                    controller.content.map { $0.canExpand && !$0.tokens.isEmpty } ?? false
                }
            )
            await app.idle()
        }
    }
}

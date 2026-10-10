// The diff's performance budgets, opt-in: skipped unless ESPALIER_PERF_REPO
// names a large clone (a temporary local clone of it is what's measured).
// Run in release:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --enable-testable-imports --filter DiffPerformanceTests
//
// Budgets: a DiffDocument of 10,000 lines builds in 10 ms; opening a
// file's diff (git's diff, the document, the table's first rows painted)
// takes under 100 ms at p50 and p95 over 20 files, small to large; and
// scrolling a 100,000-line diff draws each screen of new rows within a
// 120 Hz frame.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

/// Milliseconds, for reporting.
private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The value at a percentile of sorted values.
private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else {
        return 0
    }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
    return sorted[index]
}

/// Draws the table's visible rows (or a band of them), as a display pass
/// does.
@MainActor
private func paint(_ controller: DiffTableController, band: CGRect? = nil) {
    let table = controller.tableView
    table.layoutSubtreeIfNeeded()
    let rect = band ?? table.visibleRect
    guard let rep = table.bitmapImageRepForCachingDisplay(in: rect) else {
        return
    }
    table.cacheDisplay(in: rect, to: rep)
}

@Suite("Diff performance", .enabled(if: perfRepository != nil), .serialized) @MainActor
struct DiffPerformanceTests {
    /// A diff with about `diffLines` lines in hunks of ten changed lines.
    private func diff(lines diffLines: Int) -> TextDiff {
        // Each hunk has a header, two context lines, and ten deleted and ten
        // added lines: 23 lines for every 10 changed.
        DiffFixtures.large(lines: diffLines * 10 / 23)
    }

    @Test("a 10,000-line DiffDocument builds within 10 ms")
    func documentBuild() {
        let diff = diff(lines: 10_000)
        let input = DiffDocumentInput(hunks: diff.hunks, maxLineNumber: diff.maxLineNumber, isSplit: false)
        let lineCount = diff.hunks.reduce(0) { $0 + $1.lines.count }
        var times: [Double] = []
        for _ in 0..<9 {
            let duration = ContinuousClock().measure {
                _ = DiffDocument(input: input)
            }
            times.append(milliseconds(duration))
        }
        let split = DiffDocumentInput(hunks: diff.hunks, maxLineNumber: diff.maxLineNumber, isSplit: true)
        let splitTime = milliseconds(ContinuousClock().measure { _ = DiffDocument(input: split) })
        times.sort()
        let median = times[times.count / 2]
        print("DiffDocument: \(lineCount) lines, median \(String(format: "%.2f", median)) ms unified, \(String(format: "%.2f", splitTime)) ms split")
        #expect(median < 10)
    }

    @Test("opening 20 files' diffs paints within 100 ms at p50 and p95")
    func openFiles() async throws {
        let source = try #require(perfRepository)
        try await withIsolatedGitConfig { _ in
            let clone = try createTempDirectory(prefix: "diff-perf-")
            let cloned = try await Dugite.exec(["clone", "--quiet", "--local", "--no-checkout", source, clone], clone)
            #expect(cloned.exitCode == 0)
            let repository = Repository(path: clone)

            // Files changed in recent commits: one large, six medium, the
            // rest small (numstat's added and deleted lines).
            let log = try await runGit(["log", "--no-merges", "--numstat", "--format=commit %H", "-n", "3000"], repository)
            var changes: [(sha: String, path: String, lines: Int)] = []
            var sha = ""
            for line in log.split(separator: "\n") {
                if line.hasPrefix("commit ") {
                    sha = String(line.dropFirst(7))
                    continue
                }
                let fields = line.split(separator: "\t", maxSplits: 2)
                guard fields.count == 3, let added = Int(fields[0]), let deleted = Int(fields[1]), !fields[2].contains("=>") else {
                    continue
                }
                changes.append((sha, String(fields[2]), added + deleted))
            }
            let large = try #require(changes.filter { (3_000...40_000).contains($0.lines) }.max { $0.lines < $1.lines })
            let medium = changes.filter { (200...2_000).contains($0.lines) }.prefix(6)
            let small = changes.filter { (1...199).contains($0.lines) }.prefix(13)
            let chosen = [large] + Array(medium) + Array(small)
            #expect(chosen.count == 20)

            let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            let controller = DiffTableController()
            controller.scrollView.frame = window.contentLayoutRect
            window.contentView = controller.scrollView
            defer { window.contentView = nil }

            var times: [Double] = []
            var breakdown: [(git: Double, rest: Double, lines: Int)] = []
            for change in chosen {
                let changeset = try await getChangedFiles(repository, change.sha)
                guard let file = changeset.files.first(where: { $0.path == change.path }) else {
                    continue
                }
                let clock = ContinuousClock()
                let start = clock.now
                let diff = try await getCommitDiff(repository, file, change.sha)
                let loaded = clock.now
                let text: TextDiff
                switch diff {
                case .text(let value): text = value
                case .largeText(let value): text = TextDiff(value)
                default: continue
                }
                var painted: ContinuousClock.Instant?
                controller.actions = DiffTableActions(didPaint: { _ in painted = painted ?? clock.now })
                controller.apply(DiffTableContent(fileID: "\(change.sha):\(change.path)", diff: text))
                await controller.documentIdle()
                if painted == nil {
                    paint(controller)
                }
                let end = painted ?? clock.now
                times.append(milliseconds(end - start))
                breakdown.append((milliseconds(loaded - start), milliseconds(end - loaded), controller.document.rowCount))
            }
            let sorted = times.sorted()
            let p50 = percentile(sorted, 0.5)
            let p95 = percentile(sorted, 0.95)
            print("Diff open: \(times.count) files, p50 \(String(format: "%.1f", p50)) ms, p95 \(String(format: "%.1f", p95)) ms")
            for (index, item) in breakdown.enumerated() {
                print(String(format: "  %6d rows: git %.1f ms, document and first paint %.1f ms, total %.1f ms", item.lines, item.git, item.rest, times[index]))
            }
            #expect(p50 < 100)
            #expect(p95 < 100)
        }
    }

    @Test("scrolling a 100,000-line diff draws each screen within a 120 Hz frame", arguments: [false, true])
    func scrolling(staged: Bool) async {
        let diff = diff(lines: 100_000)
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let controller = DiffTableController()
        controller.scrollView.frame = window.contentLayoutRect
        window.contentView = controller.scrollView
        defer { window.contentView = nil }

        // Staged, as in Changes: every changed line's number cells show
        // whether it's included, every third line of the rows scrolled
        // through left out (faded and struck through).
        var staging: StagingState?
        if staged {
            let changed = diff.hunks.flatMap(\.lines).compactMap { $0.isIncludeableLine() ? $0.originalLineNumber : nil }
            var selection = DiffSelection.fromInitialSelection(.all).withSelectableLines(Set(changed))
            for line in changed.prefix(while: { $0 < 30_000 }) where line % 3 == 0 {
                selection = selection.withLineSelection(line, selected: false)
            }
            staging = StagingState(selection: selection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
        }

        let clock = ContinuousClock()
        let start = clock.now
        controller.apply(DiffTableContent(fileID: "big", diff: diff, isSplit: false, staging: staging))
        await controller.documentIdle()
        paint(controller)
        let opened = milliseconds(clock.now - start)

        // Scroll a third of a screen per frame, as a fast flick does, through
        // the first 20,000 rows. A frame lays the table out and draws the
        // band of rows the scroll exposes (layer-backed rows that stay on
        // screen move without redrawing).
        let clip = controller.scrollView.contentView
        let step = clip.bounds.height / 3
        var frames: [Double] = []
        var fullScreens: [Double] = []
        var y: CGFloat = 0
        let limit = controller.tableView.rect(ofRow: min(20_000, controller.document.rowCount - 1)).maxY
        while y < limit {
            y += step
            let duration = clock.measure {
                clip.scroll(to: CGPoint(x: 0, y: y))
                controller.scrollView.reflectScrolledClipView(clip)
                let visible = controller.tableView.visibleRect
                paint(controller, band: CGRect(x: visible.minX, y: visible.maxY - step, width: visible.width, height: step))
            }
            frames.append(milliseconds(duration))
            if frames.count % 50 == 0 {
                fullScreens.append(milliseconds(clock.measure { paint(controller) }))
            }
        }
        let sorted = frames.sorted()
        let full = fullScreens.sorted()
        print("Scrolling \(controller.document.rowCount) rows\(staged ? ", staged" : ""): opened in \(String(format: "%.1f", opened)) ms; \(frames.count) frames, p50 \(String(format: "%.2f", percentile(sorted, 0.5))) ms, p95 \(String(format: "%.2f", percentile(sorted, 0.95))) ms, max \(String(format: "%.2f", sorted.last ?? 0)) ms; a whole screen redrawn: p50 \(String(format: "%.2f", percentile(full, 0.5))) ms")
        #expect(percentile(sorted, 0.95) < 8.3)
    }
}

// The Changes Apply benchmark: how long the Changes list takes to show a new
// status, measured offscreen with the list's own rows and style. The budget
// is one frame for 5,000 files and 50 ms for 50,000. The Debug menu
// runs it (`Benchmarks.runners[.changesApply]`), and so do the opt-in
// performance tests.

import AppKit
import EspalierCore
import GitKit
import Observation
import QuartzCore
import SwiftUI

/// Measures applying a status to the Changes list.
@MainActor
enum ChangesApplyBenchmark {
    /// One size's timings.
    struct Result: Sendable {
        let fileCount: Int
        /// The list's first layout and drawing.
        let firstLayout: Duration
        /// A new list of files (every row new), the median of the runs.
        let replace: Duration
        /// The same files with every checkbox changed, the median.
        let inclusionChange: Duration

        /// Whether the table showed each status when its time was taken.
        let isVerified: Bool

        /// The slower of the two applies.
        var apply: Duration {
            max(replace, inclusionChange)
        }
    }

    /// The sizes the budget names.
    static let sizes = [5_000, 50_000]

    /// Lays out a list of `fileCount` files in a column-sized offscreen
    /// window, then applies new statuses to it and times each until it's
    /// laid out and drawn.
    static func measure(fileCount: Int, runs: Int = 5) -> Result {
        let box = BenchmarkFiles(files(fileCount, variant: 0, included: true))
        let host = NSHostingView(rootView: BenchmarkList(box: box))
        let size = CGSize(width: Metrics.Column.changesFileList.ideal, height: Metrics.Window.defaultHeight)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let clock = ContinuousClock()

        let firstLayout = clock.measure {
            flush(host)
        }

        var replacements: [Duration] = []
        var inclusionChanges: [Duration] = []
        var isVerified = shows(box.files, in: host)
        for run in 1...max(runs, 1) {
            let replaced = files(fileCount, variant: run, included: true)
            replacements.append(clock.measure {
                box.files = replaced
                flush(host)
            })
            isVerified = isVerified && shows(replaced, in: host)
            let toggled = replaced.map { $0.withIncludeAll(run.isMultiple(of: 2)) }
            inclusionChanges.append(clock.measure {
                box.files = toggled
                flush(host)
            })
            isVerified = isVerified && shows(toggled, in: host)
        }
        return Result(
            fileCount: fileCount,
            firstLayout: firstLayout,
            replace: median(replacements),
            inclusionChange: median(inclusionChanges),
            isVerified: isVerified
        )
    }

    /// Does a frame's work for what changed: SwiftUI's update and AppKit's
    /// layout (`layoutSubtreeIfNeeded` runs both), then the drawing (the
    /// layer tree's commit displays the layers that need it).
    static func flush(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    /// Whether the table in `host` shows `files`: their count, and the
    /// first row's file and checkbox.
    static func shows(_ files: [WorkingDirectoryFileChange], in host: NSView) -> Bool {
        guard let table = table(in: host), table.numberOfRows == files.count else {
            return false
        }
        guard let first = files.first else {
            return true
        }
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? FileRowView,
              let content = cell.content
        else {
            return false
        }
        return content.id == first.id && content.inclusion == BenchmarkList.inclusion(first).value
    }

    /// The Changes table under `view`.
    static func table(in view: NSView) -> ChangesTableView? {
        if let table = view as? ChangesTableView {
            return table
        }
        for subview in view.subviews {
            if let table = table(in: subview) {
                return table
            }
        }
        return nil
    }

    /// The Debug menu's report.
    static func run() -> String {
        let results = sizes.map { measure(fileCount: $0) }
        let parts = results.map { result in
            "\(formatNumber(Double(result.fileCount))) files \(milliseconds(result.apply)) ms"
        }
        return "Changes Apply: " + parts.joined(separator: " · ") + " (median of 5)"
    }

    /// `count` changed files: modified, new, deleted, and renamed, in
    /// folders, with paths that differ per variant.
    static func files(_ count: Int, variant: Int, included: Bool) -> [WorkingDirectoryFileChange] {
        (0..<count).map { index in
            let path = "Sources/Module\(index % 97)/Variant\(variant)/File\(index).swift"
            let status: AppFileStatus = switch index % 4 {
            case 0: .new()
            case 1: .deleted()
            case 2: .renamed(oldPath: "Sources/Old/File\(index).swift", renameIncludesModifications: true)
            default: .modified()
            }
            return WorkingDirectoryFileChange(path: path, status: status, selection: DiffSelection.fromInitialSelection(included ? .all : .none))
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }

    private static func median(_ samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }
}

/// The files the benchmark's list shows.
@MainActor @Observable
final class BenchmarkFiles {
    var files: [WorkingDirectoryFileChange]

    init(_ files: [WorkingDirectoryFileChange]) {
        self.files = files
    }
}

/// The Changes list's table, without a model.
struct BenchmarkList: View {
    let box: BenchmarkFiles

    var body: some View {
        FileTable(files: .changes(box.files), selectedIDs: [], inclusion: Self.inclusion)
    }

    /// A file's checkbox from its selection alone.
    static func inclusion(_ file: WorkingDirectoryFileChange) -> FileInclusionState {
        let value: Bool? = switch file.selection.getSelectionType() {
        case .all: true
        case .none: false
        case .partial: nil
        }
        return FileInclusionState(value: value, isEnabled: true, help: nil)
    }
}

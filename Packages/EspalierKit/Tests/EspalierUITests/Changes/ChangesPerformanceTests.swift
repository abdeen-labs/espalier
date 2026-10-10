// The Changes list's performance budget: a status for 5,000 files applies in
// under one frame, and for 50,000 in under 50 ms. Opt-in: skipped unless
// ESPALIER_PERF_REPO points at a large clone; the end-to-end test modifies a
// local clone of it, never the repository itself. Timings are printed.

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

/// The repository the performance tests clone, if set.
private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

@Suite("Changes performance", .serialized, .enabled(if: perfRepository != nil), .offline) @MainActor
struct ChangesPerformanceTests {
    /// One frame at 60 Hz.
    private static let frame: Duration = .microseconds(16_667)

    @Test("the list shows a new status for 5,000 files in a frame, 50,000 in 50 ms")
    func listApply() {
        // SwiftUI's first layout in a process is slow; warm it up.
        _ = ChangesApplyBenchmark.measure(fileCount: 100, runs: 1)
        let small = ChangesApplyBenchmark.measure(fileCount: 5_000)
        let large = ChangesApplyBenchmark.measure(fileCount: 50_000)
        for result in [small, large] {
            print("ChangesApply list \(result.fileCount) files: first layout \(ChangesApplyBenchmark.milliseconds(result.firstLayout)) ms, "
                + "new files \(ChangesApplyBenchmark.milliseconds(result.replace)) ms, "
                + "checkboxes \(ChangesApplyBenchmark.milliseconds(result.inclusionChange)) ms")
            #expect(result.isVerified, "the table didn't show each status when its time was taken")
        }
        #expect(small.apply < Self.frame)
        #expect(large.apply < .milliseconds(50))
    }

    @Test("a real status pass applies to the Changes place within the budget")
    func modelApply() async throws {
        let source = try #require(perfRepository)
        try await withIsolatedGitConfig { _ in
            // A local clone (objects linked), with up to 5,000 files changed.
            let path = try createTempDirectory(prefix: "espalier-perf-")
            try await runGit(["clone", "--local", "--quiet", source, path], Repository(path: path))
            let clone = Repository(path: path)
            let tracked = try await runGit(["ls-files", "-z"], clone).split(separator: "\0").map(String.init)
            let changed = Array(tracked.prefix(5_000))
            for file in changed {
                let url = URL(filePath: POSIXPath.join(clone.path, file))
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    continue
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
                try handle.close()
            }

            let fixture = try await ChangesWindowFixture.make(clone)
            // Two statuses that differ at the top of the list: the second
            // adds 50 new files at the root.
            let first = try #require(try await getStatus(clone))
            for index in 0..<50 {
                try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(clone.path, "0-perf-\(index).txt")))
            }
            let second = try #require(try await getStatus(clone))
            let host = NSHostingView(rootView: ChangesScreen(repository: fixture.repository).windowEnvironment(fixture.context))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            defer { window.contentView = nil }
            ChangesApplyBenchmark.flush(host)

            // Apply each status as the refresher does (the model's part),
            // then lay out and draw (the UI's part).
            let clock = ContinuousClock()
            var models: [Duration] = []
            var views: [Duration] = []
            for run in 0..<6 {
                let status = run.isMultiple(of: 2) ? second : first
                models.append(clock.measure {
                    fixture.repository.changes.reconcile(status, options: [])
                })
                views.append(clock.measure {
                    ChangesApplyBenchmark.flush(host)
                })
                let table = try #require(ChangesApplyBenchmark.table(in: host))
                #expect(table.numberOfRows == fixture.repository.changes.visibleFiles.count)
                #expect(table.numberOfRows == status.workingDirectory.files.count)
            }
            let model = models.sorted()[models.count / 2]
            let view = views.sorted()[views.count / 2]
            let count = second.workingDirectory.files.count
            print("ChangesApply model \(count) files: reconcile \(ChangesApplyBenchmark.milliseconds(model)) ms (slice C), "
                + "list and composer \(ChangesApplyBenchmark.milliseconds(view)) ms (median of \(views.count))")
            #expect(count > 0)
            #expect(view < (count <= 5_000 ? Self.frame : .milliseconds(50)))
            await fixture.app.idle()
        }
    }
}

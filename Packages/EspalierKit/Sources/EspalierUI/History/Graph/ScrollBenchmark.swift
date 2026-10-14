// The Debug menu's History Scroll Benchmark. It scrolls the graph
// from top to bottom at a fixed speed on the window's display link, counts
// the frames that took longer than 1.5 times the display's interval
// (hitches), and reports the hitch time per second of scrolling.

import AppKit
import EspalierCore
import GitKit
import QuartzCore

/// Runs the History Scroll Benchmark in a window.
@MainActor
enum HistoryScrollBenchmark {
    /// The scroll speed, in points per second.
    static let speed: CGFloat = 4_000
    /// The benchmark stops after this long even if the history goes on.
    static let maximumDuration: CFTimeInterval = 120

    /// Scrolls the window's graph and returns the result in words.
    static func run(in context: WindowContext) async -> String {
        guard let controller = context.state.history.controller, controller.tableView.window != nil else {
            return "Show History to run the History Scroll Benchmark."
        }
        controller.scroll(toY: 0, animated: false)
        let result = await ScrollRun(controller: controller).run()
        return result.summary(context.app.preferences.numberFormat)
    }
}

/// What a scroll run measured.
nonisolated struct ScrollRunResult: Sendable, Equatable {
    var rows: Int
    var duration: CFTimeInterval
    var frames: Int
    var hitches: Int
    /// The time hitches added beyond the display's interval.
    var hitchTime: CFTimeInterval

    /// Milliseconds of hitches per second of scrolling.
    var hitchTimeRatio: Double {
        duration > 0 ? hitchTime * 1_000 / duration : 0
    }

    /// The result in words, counts in `numberFormat`.
    func summary(_ numberFormat: NumberFormat) -> String {
        let seconds = String(format: "%.1f", duration)
        let ratio = String(format: "%.1f", hitchTimeRatio)
        let hitchWord = hitches == 1 ? "hitch" : "hitches"
        return "Scrolled \(formatCount(rows, numberFormat)) commits in \(seconds) s: \(formatCount(frames, numberFormat)) frames, \(hitches) \(hitchWord), \(ratio) ms/s"
    }

    /// Counts a frame of `length` seconds against the display's `interval`:
    /// a frame longer than 1.5 intervals is a hitch.
    mutating func record(frame length: CFTimeInterval, interval: CFTimeInterval) {
        frames += 1
        duration += length
        if interval > 0, length > interval * 1.5 {
            hitches += 1
            hitchTime += length - interval
        }
    }
}

/// One run: scrolls on each display-link frame until the end.
@MainActor
private final class ScrollRun: NSObject {
    private let controller: GraphTableController
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<ScrollRunResult, Never>?
    private var lastTimestamp: CFTimeInterval?
    private var result = ScrollRunResult(rows: 0, duration: 0, frames: 0, hitches: 0, hitchTime: 0)
    private var offset: CGFloat = 0

    init(controller: GraphTableController) {
        self.controller = controller
    }

    func run() async -> ScrollRunResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = controller.tableView.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let interval = link.targetTimestamp - link.timestamp
        if let last = lastTimestamp {
            let length = now - last
            result.record(frame: length, interval: interval > 0 ? interval : link.duration)
            offset += HistoryScrollBenchmark.speed * CGFloat(length)
        }
        lastTimestamp = now
        controller.scroll(toY: offset, animated: false)

        let table = controller.tableView
        let clip = controller.scrollView.contentView
        let atBottom = clip.bounds.maxY >= table.frame.height - 1
        let isComplete = controller.source?.isComplete ?? true
        if (atBottom && isComplete) || result.duration >= HistoryScrollBenchmark.maximumDuration {
            finish()
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        result.rows = controller.shownRowCount
        continuation?.resume(returning: result)
        continuation = nil
    }
}

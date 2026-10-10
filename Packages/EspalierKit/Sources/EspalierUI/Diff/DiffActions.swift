// The View menu's diff options: Split Diff, Hide Whitespace Changes (per
// place, reloading the place's diff), Wrap Lines, Image Diff, and the code
// text size; and the Debug menu's Diff Open Benchmark.

import EspalierCore
import Foundation
import GitKit

/// Registers the diff's actions.
@MainActor
enum DiffActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        let preferences = context.app.preferences

        actions.register(.toggleSplitDiff, isChecked: { _ in
            preferences.showSideBySideDiff
        }) { _ in
            preferences.showSideBySideDiff.toggle()
        }

        actions.register(.toggleHideWhitespace, isEnabled: { [weak context] _ in
            guard let context else {
                return false
            }
            return DiffWhitespace.isHidden(context: diffContext(for: context.state.place), preferences: preferences) != nil
        }, isChecked: { [weak context] _ in
            guard let context else {
                return false
            }
            return DiffWhitespace.isHidden(context: diffContext(for: context.state.place), preferences: preferences) ?? false
        }) { [weak context] _ in
            guard let context else {
                return
            }
            let diffContext = diffContext(for: context.state.place)
            guard let hidden = DiffWhitespace.isHidden(context: diffContext, preferences: preferences) else {
                return
            }
            DiffWhitespace.set(!hidden, context: diffContext, repository: context.repository, preferences: preferences)
        }

        actions.register(.toggleWrapLines, isChecked: { _ in
            preferences.wrapDiffLines
        }) { _ in
            preferences.wrapDiffLines.toggle()
        }

        actions.register(.setImageDiffType, isChecked: { action in
            guard case .setImageDiffType(let type) = action else {
                return false
            }
            return preferences.imageDiffType == type
        }) { action in
            guard case .setImageDiffType(let type) = action else {
                return
            }
            preferences.imageDiffType = type
        }

        actions.register(.increaseCodeTextSize, isEnabled: { _ in
            !preferences.codeTextSize.isLargest
        }) { _ in
            preferences.increaseCodeTextSize()
        }
        actions.register(.decreaseCodeTextSize, isEnabled: { _ in
            !preferences.codeTextSize.isSmallest
        }) { _ in
            preferences.decreaseCodeTextSize()
        }
        actions.register(.resetCodeTextSize, isEnabled: { _ in
            preferences.codeTextSize != .actual
        }) { _ in
            preferences.resetCodeTextSize()
        }

        Benchmarks.runners[.diffOpen] = { context in
            await DiffOpenBenchmark.run(in: context)
        }
    }

    /// The diff context of the place showing.
    static func diffContext(for place: SidebarPlace?) -> DiffContext {
        switch place {
        case .history?, .branch?, .tag?: .history
        case .pullRequest?: .pullRequest
        case .stash?: .stash
        case .changes?, nil: .changes
        }
    }
}

/// The Debug menu's Diff Open Benchmark: selects each changed file in
/// Changes in turn (up to 20) and reports the click-to-paint times, which
/// the `DiffOpen` signpost also measures.
@MainActor
enum DiffOpenBenchmark {
    static func run(in context: WindowContext) async -> String {
        guard let repository = context.repository else {
            return "Open a repository with changes to run the Diff Open Benchmark."
        }
        let files = Array(repository.changes.workingDirectory.files.prefix(20))
        guard !files.isEmpty else {
            return "Make some changes to run the Diff Open Benchmark."
        }
        context.select(.changes)
        let previousSelection = repository.changes.selection
        repository.changes.select(fileIDs: [])
        var durations: [Duration] = []
        for file in files {
            let probe = DiffOpenProbe.shared
            let fileID = DiffFileInfo(file).id
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    probe.cancelWait(for: fileID)
                }
            }
            async let duration = probe.waitForPaint(of: fileID)
            repository.changes.select(fileIDs: [file.id])
            let measured = await duration
            timeout.cancel()
            if measured > .zero {
                durations.append(measured)
            }
        }
        if case .workingDirectory(let fileIDs) = previousSelection {
            repository.changes.select(fileIDs: fileIDs)
        }
        guard !durations.isEmpty else {
            return "No diff painted within 5 seconds."
        }
        let sorted = durations.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return "Diff Open: \(sorted.count) files, p50 \(milliseconds(p50)) ms, p95 \(milliseconds(p95)) ms"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}

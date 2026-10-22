// The Debug menu's benchmarks. The History Scroll Benchmark is a
// display-link scroll at a fixed 120 Hz speed that counts frames longer
// than 1.5× the interval and reports the hitch-time ratio.

import EspalierCore
import GitKit
import SwiftUI

/// Registers the Debug menu's benchmarks.
@MainActor
enum Benchmarks {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.runBenchmark, isEnabled: { action in
            guard case .runBenchmark(let benchmark) = action else {
                return false
            }
            return runners[benchmark] != nil
        }) { [weak context] action in
            guard case .runBenchmark(let benchmark) = action, let context, let runner = runners[benchmark] else {
                return
            }
            let result = await runner(context)
            context.presenter.show(Toast(result, systemImage: "speedometer", tone: .notice))
        }
    }

    /// The benchmarks that exist, each returning its result in words. Each
    /// feature's actions register its own.
    static var runners: [BenchmarkID: @MainActor (WindowContext) async -> String] = [:]
}

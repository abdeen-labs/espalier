// The operation bar's step indicator: a short capsule per step, done in the
// add color, the current one in the accent (or the modified color where it
// stopped for the user), the rest in `line2`. Past a dozen steps it's one
// bar instead, filled as far as the work has gone.

import AppKit
import SwiftUI

/// How far one step has gone.
nonisolated public enum StepState: Sendable, Equatable {
    case done
    /// The step running now.
    case current
    /// The step that stopped for the user (conflicts to resolve).
    case stopped
    case pending
}

/// A row of step capsules, or one bar for many steps.
public struct StepIndicator: View {
    private let steps: [StepState]
    private let label: String

    /// - Parameters:
    ///   - steps: Each step's state, in order.
    ///   - label: What VoiceOver says ("Commit 2 of 4").
    public init(_ steps: [StepState], label: String) {
        self.steps = steps
        self.label = label
    }

    public var body: some View {
        Group {
            if steps.count <= Metrics.StepIndicator.maximumSegments {
                HStack(spacing: Metrics.StepIndicator.spacing) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Capsule(style: .circular)
                            .fill(Self.color(of: step))
                            .frame(width: Metrics.StepIndicator.segmentWidth, height: Metrics.StepIndicator.height)
                    }
                }
            } else {
                let finished = steps.filter { $0 != .pending }.count
                ZStack(alignment: .leading) {
                    Capsule(style: .circular)
                        .fill(.line2)
                    Capsule(style: .circular)
                        .fill(Self.color(of: steps.contains(.stopped) ? .stopped : .done))
                        .frame(width: Metrics.StepIndicator.barWidth * CGFloat(finished) / CGFloat(max(steps.count, 1)))
                }
                .frame(width: Metrics.StepIndicator.barWidth, height: Metrics.StepIndicator.height)
            }
        }
        // A step moving forward changes its segment's color (or fills the
        // bar) over 0.22 s.
        .motion(Motion.arrive, value: steps)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    static func color(of step: StepState) -> Color {
        switch step {
        case .done: Color(espalier: Palette.success)
        case .current: .accentColor
        case .stopped: Color(espalier: Palette.warningMark)
        case .pending: .line2
        }
    }
}

extension StepIndicator {
    /// Steps for an operation at `position` of `total` (1-based): the ones
    /// before it done, it current (or stopped), the rest pending.
    nonisolated public static func steps(position: Int, total: Int, isStopped: Bool = false) -> [StepState] {
        guard total > 0 else {
            return []
        }
        let position = min(max(position, 1), total)
        return (1...total).map { step in
            if step < position {
                .done
            } else if step == position {
                isStopped ? .stopped : .current
            } else {
                .pending
            }
        }
    }
}

extension Metrics {
    /// The step indicator.
    public enum StepIndicator {
        public static let segmentWidth: CGFloat = 22
        public static let height: CGFloat = 4
        public static let spacing: CGFloat = 3
        /// Past this many steps, one bar.
        public static let maximumSegments = 12
        /// The one bar's width.
        public static let barWidth: CGFloat = 120
    }
}

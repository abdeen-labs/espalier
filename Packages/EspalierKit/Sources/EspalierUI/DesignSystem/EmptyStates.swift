// Loading and placeholder states. Empty and failure states are
// `CenteredMessage`s, and spinners appear only after 300 ms.

import SwiftUI

/// A quiet, centered line of tertiary text, such as "Select a file to see
/// its changes".
public struct PlaceholderNote: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.row)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(Metrics.insetLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A spinner (`ArcProgress`), centered in the space it's given, that
/// appears only after a delay (300 ms by default), so work that finishes
/// quickly shows nothing; it fades in over 0.22 s.
public struct DelayedProgressView: View {
    private let size: Metrics.Progress.ArcSize
    private let delay: Duration
    @State private var isVisible = false
    @Environment(\.motion) private var motion

    /// - Parameter size: Large alone in a pane, small in a row.
    public init(_ size: Metrics.Progress.ArcSize = .large, delay: Duration = Timing.spinnerDelay) {
        self.size = size
        self.delay = delay
    }

    public var body: some View {
        ZStack {
            if isVisible {
                ArcProgress(size)
                    .transition(motion.animates ? .opacity : .identity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: delay)
            withMotion(motion, Motion.arrive) {
                isVisible = true
            }
        }
    }
}

/// Placeholder rows shown while a list's first load runs (up to 300 ms,
/// then a spinner).
public struct PlaceholderRows: View {
    private let count: Int

    public init(count: Int = 6) {
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(0..<count, id: \.self) { index in
                Text(String(repeating: "Placeholder ", count: 2 + index % 3))
                    .font(Typography.row)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
        .padding(Metrics.insetMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Background failures: the selected repository's last one shows quietly on
// the sync button.

import EspalierCore
import GitKit
import SwiftUI

/// What the sync button says about a background failure.
nonisolated public struct BackgroundFailureSummary: Sendable, Equatable {
    /// The error's title ("Error", "Failed to push").
    public var title: String
    public var message: String
    /// The recoveries' button titles.
    public var recoveryTitles: [String]

    public init(title: String, message: String, recoveryTitles: [String] = []) {
        self.title = title
        self.message = message
        self.recoveryTitles = recoveryTitles
    }

    public init(_ failure: BackgroundFailure) {
        self.init(title: failure.error.title, message: failure.error.message, recoveryTitles: failure.error.recoveries.map(\.title))
    }

    /// The sync menu's line: "Background fetch failed: <title>".
    public var menuTitle: String {
        "Background fetch failed: \(title)"
    }
}

/// The small warning badge on the sync button.
public struct BackgroundFailureBadge: View {
    public init() {}

    public var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .font(.system(size: 9, weight: .semibold))
            .accessibilityLabel("Background fetch failed")
    }
}

/// The details popover: the error's message and its recoveries.
public struct BackgroundFailureDetails: View {
    private let summary: BackgroundFailureSummary
    private let onRecovery: (Int) -> Void

    public init(_ summary: BackgroundFailureSummary, onRecovery: @escaping (Int) -> Void = { _ in }) {
        self.summary = summary
        self.onRecovery = onRecovery
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Label {
                Text(summary.menuTitle)
                    .font(Typography.heading)
                    .foregroundStyle(.text)
            } icon: {
                WarningGlyph()
            }
            Text(summary.message)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !summary.recoveryTitles.isEmpty {
                HStack(spacing: Metrics.insetSmall) {
                    Spacer()
                    ForEach(Array(summary.recoveryTitles.enumerated()), id: \.offset) { index, title in
                        Button(title) {
                            onRecovery(index)
                        }
                        .buttonStyle(.quiet)
                    }
                }
                .controlSize(.small)
                .padding(.top, Metrics.grid)
            }
        }
        .padding(Metrics.Popover.padding)
        .frame(width: Metrics.Popover.width, alignment: .leading)
        .background(Color(espalier: Palette.background))
        .flatPopoverPresentation()
    }
}

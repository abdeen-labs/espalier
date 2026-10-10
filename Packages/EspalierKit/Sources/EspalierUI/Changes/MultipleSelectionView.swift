// What the diff's side shows while several changed files are selected: their
// count, and the actions that apply to all of them.

import GitKit
import SwiftUI

/// What the multiple selection view shows.
nonisolated public struct MultipleSelectionContent: Sendable, Equatable {
    /// "3 Files Selected".
    public var title: String
    /// Whether Include and Exclude can run (not while committing, not in a
    /// rebase's conflicts).
    public var canChangeInclusion: Bool
    /// Whether Discard Changes… can run (not while committing).
    public var canDiscard: Bool

    public init(title: String, canChangeInclusion: Bool = true, canDiscard: Bool = true) {
        self.title = title
        self.canChangeInclusion = canChangeInclusion
        self.canDiscard = canDiscard
    }

    /// The title for `count` files.
    public static func title(count: Int, numberFormat: NumberFormat) -> String {
        "\(formatNumber(Double(count), numberFormat)) Files Selected"
    }
}

/// Several selected files: their count, Include, Exclude, and Discard
/// Changes….
public struct MultipleSelectionView: View {
    private let content: MultipleSelectionContent
    private let onInclude: () -> Void
    private let onExclude: () -> Void
    private let onDiscard: () -> Void

    public init(
        _ content: MultipleSelectionContent,
        onInclude: @escaping () -> Void = {},
        onExclude: @escaping () -> Void = {},
        onDiscard: @escaping () -> Void = {}
    ) {
        self.content = content
        self.onInclude = onInclude
        self.onExclude = onExclude
        self.onDiscard = onDiscard
    }

    public var body: some View {
        CenteredMessage(content.title, systemImage: "doc.on.doc") {
            HStack(spacing: Metrics.insetSmall) {
                Button("Include", action: onInclude)
                    .disabled(!content.canChangeInclusion)
                Button("Exclude", action: onExclude)
                    .disabled(!content.canChangeInclusion)
                Button("Discard Changes…", action: onDiscard)
                    .disabled(!content.canDiscard)
            }
            .buttonStyle(.quiet)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

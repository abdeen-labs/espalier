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

/// Several selected files: a plain symbol, their count, a line about
/// what can be done with them, and Include, Exclude, and Discard Changes….
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
        VStack(spacing: 0) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: CenteredMessageMetrics.largeSymbol))
                .foregroundStyle(.text3)
                .padding(.bottom, Metrics.MultipleSelection.symbolSpacing)
                .accessibilityHidden(true)
            Text(content.title)
                .font(Typography.display(size: Metrics.MultipleSelection.titleSize))
                .foregroundStyle(.text)
                .accessibilityAddTraits(.isHeader)
            Text("Include them in the commit, leave them out, or discard their changes.")
                .font(Typography.row)
                .foregroundStyle(.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Metrics.insetSmall)
            HStack(spacing: Metrics.insetSmall) {
                Button("Include", systemImage: "checkmark", action: onInclude)
                    .disabled(!content.canChangeInclusion)
                Button("Exclude", systemImage: "minus", action: onExclude)
                    .disabled(!content.canChangeInclusion)
                Button("Discard Changes…", systemImage: "trash", action: onDiscard)
                    .disabled(!content.canDiscard)
            }
            .buttonStyle(.quiet)
            .fixedSize()
            .padding(.top, Metrics.MultipleSelection.buttonsSpacing)
        }
        .frame(maxWidth: Metrics.MultipleSelection.width)
        .padding(Metrics.insetLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Metrics {
    /// Several selected files' view.
    public enum MultipleSelection {
        public static let width: CGFloat = 440
        public static let symbolSpacing: CGFloat = 14
        public static let titleSize: CGFloat = 20
        public static let buttonsSpacing: CGFloat = 18
    }
}

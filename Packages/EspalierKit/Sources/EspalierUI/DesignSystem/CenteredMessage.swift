// A centered message: a large plain symbol (in tertiary text, or the
// message's tint), a bold title in display type, a plain sentence about
// it, and its actions below. Every centered empty or failure state uses it: Changes' empty state, the diff's states (binary,
// too large, no content changes, a failed load), no repository selected, a
// missing repository, a launch failure, and the history's and pull
// requests' empty and failed loads.

import SwiftUI

extension Typography {
    /// A centered message's title: display type, 17 bold.
    static var messageTitle: Font { display(size: 17) }
    /// A large centered message's title: display type, 22 bold.
    static var largeMessageTitle: Font { display(size: 22) }
}

/// A centered message: a large symbol, a title, a description, and actions
/// below.
public struct CenteredMessage<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: AttributedString?
    private let tint: Color?
    private let isLarge: Bool
    private let maximumWidth: CGFloat
    private let actions: Actions

    /// - Parameters:
    ///   - tint: The symbol's color (the check of "No local changes" is
    ///     green, a failure's warning the modified color); nil for
    ///     tertiary text.
    ///   - isLarge: A place's own message (the larger symbol and title)
    ///     rather than a pane's.
    ///   - maximumWidth: The widest the title, the description, and the
    ///     actions get.
    public init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        tint: Color? = nil,
        isLarge: Bool = false,
        maximumWidth: CGFloat = CenteredMessageMetrics.maximumWidth,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title,
            systemImage: systemImage,
            attributedDescription: description.map { AttributedString($0) },
            tint: tint,
            isLarge: isLarge,
            maximumWidth: maximumWidth,
            actions: actions
        )
    }

    /// A message whose description has links (a missing repository's
    /// "Check again."), which the environment's `openURL` opens.
    public init(
        _ title: String,
        systemImage: String,
        attributedDescription: AttributedString?,
        tint: Color? = nil,
        isLarge: Bool = false,
        maximumWidth: CGFloat = CenteredMessageMetrics.maximumWidth,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = attributedDescription
        self.tint = tint
        self.isLarge = isLarge
        self.maximumWidth = maximumWidth
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: isLarge ? CenteredMessageMetrics.largeSymbol : CenteredMessageMetrics.symbol, weight: .regular))
                .foregroundStyle(tint ?? .text3)
                .accessibilityHidden(true)
            Text(title)
                .font(isLarge ? Typography.largeMessageTitle : Typography.messageTitle)
                .foregroundStyle(.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, CenteredMessageMetrics.titleTopPadding)
                .accessibilityAddTraits(.isHeader)
            if let description {
                LinkedText(description)
                    .font(isLarge ? Typography.row : Typography.secondary)
                    .foregroundStyle(.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, CenteredMessageMetrics.descriptionTopPadding)
            }
            actions
                .padding(.top, CenteredMessageMetrics.actionsTopPadding)
        }
        .frame(maxWidth: maximumWidth)
        .padding(Metrics.insetLarge)
        .accessibilityElement(children: .contain)
    }
}

/// A centered message's sizes. The cloning view, centered too, shares its
/// widest width.
public enum CenteredMessageMetrics {
    /// The symbol's point size: a place's message, and a pane's.
    static let largeSymbol: CGFloat = 44
    static let symbol: CGFloat = 36
    /// Above the title, the description, and the actions.
    static let titleTopPadding: CGFloat = 14
    static let descriptionTopPadding: CGFloat = 6
    static let actionsTopPadding: CGFloat = 20
    /// The widest a centered message gets.
    public static let maximumWidth: CGFloat = 620
}

extension CenteredMessage where Actions == EmptyView {
    public init(_ title: String, systemImage: String, description: String? = nil, tint: Color? = nil, isLarge: Bool = false) {
        self.init(title, systemImage: systemImage, description: description, tint: tint, isLarge: isLarge) {
            EmptyView()
        }
    }
}

extension View {
    /// Fills the space it's offered, centered, with a minimum size of zero.
    /// A message whose text wraps reports a taller minimum the narrower it
    /// is offered; in a split view's column that minimum can exceed the
    /// window's height, and AppKit's constraint passes never settle.
    func fillingSpace() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

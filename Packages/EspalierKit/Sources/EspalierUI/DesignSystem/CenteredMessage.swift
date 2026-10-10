// A centered message: a symbol in a soft circle, a title, a line about it,
// and its actions below. Every centered empty or failure state uses it:
// Changes' empty state, the diff's states (binary, too large, no content
// changes, a failed load), no repository selected, a missing repository, a
// launch failure, and the history's and pull requests' empty and failed
// loads.

import SwiftUI

/// A centered message: a symbol in a soft circle, a title, a description,
/// and actions below.
public struct CenteredMessage<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: AttributedString?
    private let tint: Color?
    private let isLarge: Bool
    private let actions: Actions

    /// - Parameters:
    ///   - tint: The symbol's color (the check of "No local changes" is
    ///     green, a failure's warning the modified color); nil for
    ///     secondary text.
    ///   - isLarge: A place's own message (the larger circle and title)
    ///     rather than a pane's.
    public init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        tint: Color? = nil,
        isLarge: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title,
            systemImage: systemImage,
            attributedDescription: description.map { AttributedString($0) },
            tint: tint,
            isLarge: isLarge,
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
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = attributedDescription
        self.tint = tint
        self.isLarge = isLarge
        self.actions = actions()
    }

    public var body: some View {
        let circle = isLarge ? CenteredMessageMetrics.largeCircle : CenteredMessageMetrics.circle
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: circle * CenteredMessageMetrics.symbolScale, weight: .semibold))
                .foregroundStyle(tint ?? .text2)
                .frame(width: circle, height: circle)
                .background(Circle().fill(.field))
                .accessibilityHidden(true)
            Text(title)
                .font(isLarge ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Metrics.insetLarge)
                .accessibilityAddTraits(.isHeader)
            if let description {
                Text(description)
                    .font(isLarge ? Typography.row : Typography.secondary)
                    .foregroundStyle(.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Metrics.grid)
            }
            actions
                .padding(.top, Metrics.insetLarge)
        }
        .frame(maxWidth: CenteredMessageMetrics.maximumWidth)
        .padding(Metrics.insetLarge)
        .accessibilityElement(children: .contain)
    }
}

/// A centered message's sizes. The cloning view, centered too, shares its
/// widest width.
enum CenteredMessageMetrics {
    /// The soft circle's diameter: a place's message, and a pane's.
    static let largeCircle: CGFloat = 56
    static let circle: CGFloat = 44
    /// The symbol's size, as a fraction of the circle's.
    static let symbolScale: CGFloat = 0.4
    /// The widest a centered message gets.
    static let maximumWidth: CGFloat = 620
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

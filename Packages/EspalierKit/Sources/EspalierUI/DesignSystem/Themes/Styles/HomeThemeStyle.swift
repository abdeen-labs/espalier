import SwiftUI

/// Home: its heading, the pieces of work that need the user, those in
/// progress, and the quiet repositories.
nonisolated public struct HomeThemeStyle: Sendable, Equatable {
    /// How the pieces of work that need the user are drawn.
    public enum NeedsYou: Sendable, Equatable {
        /// Cards in a grid on the backdrop, as many columns as fit: a head,
        /// the headline, a peek, and the next step as a pillow button.
        case cards
        /// One column of rows split by hairlines: the repository and the
        /// branch, then the headline and its peek in one line.
        case rows
    }

    /// How In Progress's rows sit.
    public enum InProgress: Sendable, Equatable {
        /// Together in one card on the backdrop.
        case card
        /// Split by hairlines, as Needs You's rows are.
        case hairlines
    }

    /// How a branch is labeled.
    public enum BranchLabel: Sendable, Equatable {
        /// A candy pill in the branch's color.
        case pill
        /// The name in the code font, in secondary text.
        case monospaced
    }

    /// How the quiet repositories' groups sit.
    public enum Quiet: Sendable, Equatable {
        /// Each group in a card on the backdrop.
        case cards
        /// Each group under its name and a hairline.
        case hairlines
    }

    public var needsYou: NeedsYou
    public var inProgress: InProgress
    public var quiet: Quiet
    public var branchLabel: BranchLabel
    /// The heading's size and weight.
    public var titleSize: CGFloat
    public var titleWeight: Font.Weight

    /// The current theme's.
    public static var current: HomeThemeStyle {
        Theme.current.style.home
    }

    /// Default's.
    public static let `default` = HomeThemeStyle(
        needsYou: .cards,
        inProgress: .card,
        quiet: .cards,
        branchLabel: .pill,
        titleSize: 26,
        titleWeight: .heavy
    )
    /// Frost's.
    public static let frost = HomeThemeStyle(
        needsYou: .rows,
        inProgress: .hairlines,
        quiet: .hairlines,
        branchLabel: .monospaced,
        titleSize: 20,
        titleWeight: .semibold
    )
}


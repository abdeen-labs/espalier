// A centered message: a symbol on a soft box of the message's tint (the
// field fill without one), a title in the theme's title type, a plain
// sentence about it, and its actions below. A place's own message has two
// fainter tiles tilted behind its box, arranged its own way
// (`MessageTiles`). Every centered empty or failure state uses it: Changes'
// empty state, the diff's states (binary, too large, no content changes, a
// failed load), no repository selected, a missing repository, a launch
// failure, and the history's and pull requests' empty and failed loads.

import SwiftUI

extension Typography {
    /// A centered message's title: display type, 17 bold, or the system's
    /// 15 semibold.
    static var messageTitle: Font { themedTitle(displaySize: 17, system: sans(.title3, weight: .semibold)) }
    /// A large centered message's title: display type, 22 bold, or the
    /// system's 17 semibold.
    static var largeMessageTitle: Font { themedTitle(displaySize: 22, system: sans(.title2, weight: .semibold)) }
}

/// A centered message: a large symbol, a title, a description, and actions
/// below.
public struct CenteredMessage<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: AttributedString?
    private let tint: Color?
    private let tiles: MessageTiles.Arrangement?
    private let isLarge: Bool
    private let maximumWidth: CGFloat
    private let actions: Actions

    /// - Parameters:
    ///   - tint: The symbol's color (the check of "No local changes" is
    ///     green, a failure's warning the modified color); nil for
    ///     tertiary text.
    ///   - tiles: The symbol sits on a soft tile of the tint, two fainter
    ///     tiles behind it, arranged this way.
    ///   - isLarge: A place's own message (the larger symbol and title)
    ///     rather than a pane's.
    ///   - maximumWidth: The widest the title, the description, and the
    ///     actions get.
    public init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        tint: Color? = nil,
        tiles: MessageTiles.Arrangement? = nil,
        isLarge: Bool = false,
        maximumWidth: CGFloat = CenteredMessageMetrics.maximumWidth,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title,
            systemImage: systemImage,
            attributedDescription: description.map { AttributedString($0) },
            tint: tint,
            tiles: tiles,
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
        tiles: MessageTiles.Arrangement? = nil,
        isLarge: Bool = false,
        maximumWidth: CGFloat = CenteredMessageMetrics.maximumWidth,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = attributedDescription
        self.tint = tint
        self.tiles = tiles
        self.isLarge = isLarge
        self.maximumWidth = maximumWidth
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            MessageTiles(systemImage: systemImage, tint: tint, arrangement: tiles, size: tiles == nil ? CenteredMessageMetrics.box : CenteredMessageMetrics.tile)
            Text(title)
                .font(isLarge ? Typography.largeMessageTitle : Typography.messageTitle)
                .foregroundStyle(.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, tiles == nil ? CenteredMessageMetrics.titleTopPadding : CenteredMessageMetrics.tilesTitleTopPadding)
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

/// A message's symbol on a soft tile of its tint (the field fill without
/// one): alone, a pane's box, or with two fainter tiles tilted behind it,
/// which each of a place's messages arranges its own way.
public struct MessageTiles: View {
    /// How the tiles behind sit.
    nonisolated public enum Arrangement: Sendable {
        /// Fanned out to either side: something that was here is missing.
        case fan
        /// Held up behind, like a hand of cards: something to choose.
        case hand
        /// Fallen over to either side, the front tile knocked askew:
        /// something broke.
        case tumble
        /// One up and to the left, one down and to the right, leaning
        /// together: two things that didn't meet.
        case diagonal
        /// Rising above, smaller as they go: everything's done.
        case rise
        /// Dropping in from above, one after the other: something on its
        /// way.
        case drop

        /// The front tile's tilt, in degrees.
        var frontAngle: Double {
            self == .tumble ? -6 : 0
        }

        /// The tiles behind: where each sits from the front tile's center
        /// and its size, as fractions of the front tile's side, and its
        /// tilt in degrees.
        var ghosts: [(x: CGFloat, y: CGFloat, scale: CGFloat, angle: Double)] {
            switch self {
            case .fan: [(-0.5, 0.06, 0.82, -14), (0.5, 0.06, 0.82, 14)]
            case .hand: [(-0.4, -0.22, 0.8, -18), (0.4, -0.22, 0.8, 18)]
            case .tumble: [(-0.6, 0.2, 0.68, -34), (0.62, 0.13, 0.78, 22)]
            case .diagonal: [(-0.52, -0.2, 0.74, 12), (0.52, 0.2, 0.74, 12)]
            case .rise: [(-0.54, -0.14, 0.7, -16), (0.5, -0.36, 0.54, 18)]
            case .drop: [(-0.26, -0.4, 0.72, -12), (0.3, -0.72, 0.5, 14)]
            }
        }

        /// How far the tiles behind reach above the front tile, as a
        /// fraction of its side.
        var reachAbove: CGFloat {
            max(0, ghosts.map { -$0.y + $0.scale * 0.6 - 0.5 }.max() ?? 0)
        }
    }

    private let systemImage: String
    private let tint: Color?
    private let arrangement: Arrangement?
    private let size: CGFloat

    /// - Parameter arrangement: How the tiles behind sit; nil for the tile
    ///   alone.
    public init(systemImage: String, tint: Color?, arrangement: Arrangement?, size: CGFloat = CenteredMessageMetrics.tile) {
        self.systemImage = systemImage
        self.tint = tint
        self.arrangement = arrangement
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Metrics.PlaceTiles.radiusRatio, style: .continuous)
        ZStack {
            // The tiles behind; on a glass card, cut away under the front
            // tile, which has no opaque backing there to cover them.
            ZStack {
                ForEach(Array((arrangement?.ghosts ?? []).enumerated()), id: \.offset) { _, ghost in
                    let side = size * ghost.scale
                    RoundedRectangle(cornerRadius: side * Metrics.PlaceTiles.radiusRatio, style: .continuous)
                        .fill(tint.map { $0.opacity(CenteredMessageMetrics.ghostOpacity) } ?? .field)
                        .frame(width: side, height: side)
                        .rotationEffect(.degrees(ghost.angle))
                        .offset(x: size * ghost.x, y: size * ghost.y)
                }
            }
            .mask {
                MessageTileCutout(side: Theme.current.cardIsGlass ? size : 0, angle: arrangement?.frontAngle ?? 0, radius: size * Metrics.PlaceTiles.radiusRatio)
                    .fill(style: FillStyle(eoFill: true))
            }
            shape
                .fill(tint.map { $0.opacity(CenteredMessageMetrics.tileOpacity) } ?? .field)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: size * CenteredMessageMetrics.tileSymbolScale, weight: .semibold))
                        .foregroundStyle(tint ?? .text2)
                }
                // On the pane's fill: the background where panes are
                // opaque, clear on a glass card.
                .background(shape.fill(Color(espalier: Palette.pane)))
                .rotationEffect(.degrees(arrangement?.frontAngle ?? 0))
        }
        .frame(height: size)
        .padding(.top, size * (arrangement?.reachAbove ?? 0))
        .accessibilityHidden(true)
    }
}

/// Everything around the tiles but the front tile: a region well past
/// them, with a hole the front tile's shape, `side` on a side, turned
/// `angle` degrees about the center (no hole when `side` is 0). Filled
/// even-odd.
nonisolated private struct MessageTileCutout: Shape {
    let side: CGFloat
    let angle: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let reach = max(rect.width, rect.height, side) * 4
        var path = Path(rect.insetBy(dx: -reach, dy: -reach))
        guard side > 0 else {
            return path
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tile = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        let turn = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        path.addPath(tile, transform: turn)
        return path
    }
}

/// A centered message's sizes. The cloning view, centered too, shares its
/// widest width.
public enum CenteredMessageMetrics {
    /// The tile a symbol sits on: its side, the symbol's size as a
    /// fraction of it, and its tint's opacity.
    public static let tile: CGFloat = 64
    /// A pane's message's box, alone.
    static let box: CGFloat = 52
    static let tileSymbolScale: CGFloat = 0.44
    static let tileOpacity: CGFloat = 0.16
    /// The tint's opacity on the tiles behind it.
    static let ghostOpacity: CGFloat = 0.08
    /// Above the title, under the tiles.
    static let tilesTitleTopPadding: CGFloat = 20
    /// The symbol's point size: a place's message, and a pane's.
    static let largeSymbol: CGFloat = 44
    static let symbol: CGFloat = 36
    /// Above the title, the description, and the actions.
    static let titleTopPadding: CGFloat = 16
    static let descriptionTopPadding: CGFloat = 6
    static let actionsTopPadding: CGFloat = 20
    /// The widest a centered message gets.
    public static let maximumWidth: CGFloat = 620
}

extension CenteredMessage where Actions == EmptyView {
    public init(_ title: String, systemImage: String, description: String? = nil, tint: Color? = nil, tiles: MessageTiles.Arrangement? = nil, isLarge: Bool = false) {
        self.init(title, systemImage: systemImage, description: description, tint: tint, tiles: tiles, isLarge: isLarge) {
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

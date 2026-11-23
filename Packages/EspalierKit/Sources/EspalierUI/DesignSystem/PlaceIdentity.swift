// Each place in a repository has a color and a symbol: Changes apricot,
// History teal, Branches blueberry, Tags honey, Stashes grape, Pull
// Requests plum, Worktrees leaf, and Remotes slate. The colors tint the
// places' pills and dots. `PlaceTile` draws a symbol in white on a rounded
// tile of a color: Changes' and History's in the sidebar and the toolbar's
// switcher, and Settings' panes. The colors are fixed across palettes, a
// shade deeper in dark.

import AppKit
import SwiftUI

/// A place's identity: its color and symbol.
nonisolated public enum PlaceIdentity: Sendable, Hashable, CaseIterable {
    case changes, history, branches, tags, stashes, pullRequests, worktrees, remotes

    /// The place's color.
    public var color: NSColor {
        switch self {
        case .changes: PlaceColor.apricot
        case .history: PlaceColor.teal
        case .branches: PlaceColor.blueberry
        case .tags: PlaceColor.honey
        case .stashes: PlaceColor.grape
        case .pullRequests: PlaceColor.plum
        case .worktrees: PlaceColor.leaf
        case .remotes: PlaceColor.slate
        }
    }

    /// The place's symbol.
    public var systemImage: String {
        switch self {
        case .changes: "plus.forwardslash.minus"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.trianglehead.branch"
        case .tags: "tag"
        case .stashes: "tray.full"
        case .pullRequests: PullRequestGlyph.systemImage
        case .worktrees: "square.stack.3d.up"
        case .remotes: "cloud"
        }
    }
}

/// The places' colors.
nonisolated private enum PlaceColor {
    static let apricot = NSColor.espalierDynamic(light: .hex(0xF0862A), dark: .hex(0xD9741A))
    static let teal = NSColor.espalierDynamic(light: .hex(0x1C9C9A), dark: .hex(0x178685))
    static let blueberry = NSColor.espalierDynamic(light: .hex(0x4767E0), dark: .hex(0x4A63D6))
    static let honey = NSColor.espalierDynamic(light: .hex(0xE0A21B), dark: .hex(0xC48A10))
    static let grape = NSColor.espalierDynamic(light: .hex(0x9061D6), dark: .hex(0x7D52C2))
    static let plum = NSColor.espalierDynamic(light: .hex(0xD34B8E), dark: .hex(0xBA3D7C))
    static let leaf = NSColor.espalierDynamic(light: .hex(0x3E9A57), dark: .hex(0x338448))
    static let slate = NSColor.espalierDynamic(light: .hex(0x6B7A90), dark: .hex(0x5B6A80))
}

/// A symbol on a colored tile: a rounded square of the color, a soft
/// gradient down it, and the symbol in white, bold, at about half the
/// tile's side.
public struct PlaceTile: View {
    private let systemImage: String
    private let color: NSColor
    private let size: CGFloat

    /// - Parameter size: The tile's side; the corner radius and the
    ///   symbol scale with it.
    public init(_ kind: PlaceIdentity, size: CGFloat = Metrics.PlaceTiles.small) {
        self.init(systemImage: kind.systemImage, color: kind.color, size: size)
    }

    /// A tile of any symbol and color (a Settings pane's).
    public init(systemImage: String, color: NSColor, size: CGFloat = Metrics.PlaceTiles.small) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * Metrics.PlaceTiles.radiusRatio, style: .continuous)
            .fill(Color(nsColor: color).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * Metrics.PlaceTiles.symbolRatio, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension Metrics {
    /// Tiles' default side, and their corner radius and symbol size as
    /// fractions of the side.
    public enum PlaceTiles {
        public static let small: CGFloat = 18
        public static let radiusRatio: CGFloat = 0.31
        public static let symbolRatio: CGFloat = 0.53
    }
}

// The tiles' colors by name (the places' orchard colors, and tomato), which
// Settings' panes take; the round badges that say what a toast or the
// operation capsule is about; and the app's icon, drawn from its art, which
// heads the welcome flow and About.

import AppKit
import SwiftUI

/// The tiles' colors by name: the places' (`PlaceIdentity`), and tomato.
nonisolated public enum TileColor {
    public static var apricot: NSColor { PlaceIdentity.changes.color }
    public static var teal: NSColor { PlaceIdentity.history.color }
    public static var blueberry: NSColor { PlaceIdentity.branches.color }
    public static var honey: NSColor { PlaceIdentity.tags.color }
    public static var grape: NSColor { PlaceIdentity.stashes.color }
    public static var plum: NSColor { PlaceIdentity.pullRequests.color }
    public static var leaf: NSColor { PlaceIdentity.worktrees.color }
    public static var slate: NSColor { PlaceIdentity.remotes.color }
    public static let tomato = NSColor.espalierDynamic(light: .hex(0xE0533D), dark: .hex(0xC8432F))
}

/// What a badge says happened, which picks its color.
nonisolated public enum TileMood: Sendable, Equatable {
    /// Done: leaf.
    case done
    /// Working: honey.
    case running
    /// Waiting on the user (conflicts, a rebase in between): apricot.
    case waiting
    /// A notice: slate.
    case notice

    public var color: NSColor {
        switch self {
        case .done: TileColor.leaf
        case .running: TileColor.honey
        case .waiting: TileColor.apricot
        case .notice: TileColor.slate
        }
    }
}

/// What a pillow (a toast, the operation capsule) is about, in its round
/// end: a circle of a soft tint of the mood's color, concentric with the
/// pillow's end, and the bare symbol in the color. Round and soft, so it
/// reads as a status, not a control.
public struct MoodBadge: View {
    private let mood: TileMood
    private let systemImage: String
    private let size: CGFloat

    public init(mood: TileMood, systemImage: String, size: CGFloat = Metrics.Tiles.floating) {
        self.mood = mood
        self.systemImage = systemImage
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Color(nsColor: Palette.tint(mood.color, light: Metrics.Tiles.softAlpha.light, dark: Metrics.Tiles.softAlpha.dark)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: TileSymbol.bare(systemImage))
                    .font(.system(size: size * Metrics.PlaceTiles.symbolRatio, weight: .heavy))
                    .foregroundStyle(Color(nsColor: mood.color))
            }
            .accessibilityHidden(true)
    }
}

/// Symbols as badges draw them.
nonisolated enum TileSymbol {
    /// The symbol without the circle or fill around it ("checkmark" for
    /// "checkmark.circle.fill"), where that symbol exists: the badge is its
    /// shape.
    static func bare(_ systemImage: String) -> String {
        for suffix in [".circle.fill", ".circle", ".fill"] where systemImage.hasSuffix(suffix) {
            let bare = String(systemImage.dropLast(suffix.count))
            if NSImage(systemSymbolName: bare, accessibilityDescription: nil) != nil {
                return bare
            }
        }
        return systemImage
    }
}

/// Espalier's icon, drawn from its art (light and dark) in the icon's
/// rounded square, standing on a soft shadow.
public struct AppIconArt: View {
    private let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Metrics.Tiles.iconRadiusRatio, style: .continuous)
        Group {
            if let image = AppIconArt.image(dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: Elevation.card.ring ?? .clear), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }

    /// The bundled art, light or dark.
    static func image(dark: Bool) -> NSImage? {
        let name = dark ? "AppIcon-Dark" : "AppIcon"
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "AppIcon") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

extension Metrics {
    /// The badges, and the app's icon.
    public enum Tiles {
        /// A badge's tint of its color.
        public static let softAlpha: (light: CGFloat, dark: CGFloat) = (0.16, 0.24)
        /// The app icon's corner radius, as a fraction of its side.
        public static let iconRadiusRatio: CGFloat = 0.225
        /// A toast's and the operation capsule's badge.
        public static let floating: CGFloat = 30
    }
}

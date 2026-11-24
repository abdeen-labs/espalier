// The file status tile and the checks glyphs. A file's status is a small
// tile in a tint of its color with its letter (A, M, D, R, C, U). Checks
// use distinct shapes.

import AppKit
import GitKit
import SwiftUI

/// A file's status as the lists show it.
nonisolated public enum FileStatusKind: String, CaseIterable, Sendable {
    case new, modified, deleted, renamed, copied, conflicted, resolved, untracked

    /// The status from GitKit's file status.
    public init(_ status: AppFileStatus) {
        switch status {
        case .new: self = .new
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        case .copied: self = .copied
        case .conflicted: self = .conflicted
        case .untracked: self = .untracked
        }
    }

    /// The letter on the tile.
    public var letter: String {
        switch self {
        case .new, .untracked: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflicted, .resolved: "U"
        }
    }

    /// The status's name, for tooltips and VoiceOver.
    public var title: String {
        switch self {
        case .new: "New"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .conflicted: "Conflicted"
        case .resolved: "Resolved"
        case .untracked: "Untracked"
        }
    }

    /// The status's color: additions green, deletions red, modifications
    /// and conflicts amber, renames and copies violet.
    public var color: NSColor {
        switch self {
        case .new, .untracked, .resolved: Palette.add
        case .modified, .conflicted: Palette.modified
        case .deleted: Palette.delete
        case .renamed, .copied: Palette.renamed
        }
    }
}

extension FileStatusKind {
    /// The badge's fill: a tint of the status color.
    public var tileFill: NSColor {
        let tint = Metrics.StatusTile.tint
        return Palette.tint(color, light: tint.light, dark: tint.dark)
    }

    /// The badge's letter: the status's own foreground.
    public var tileInk: NSColor {
        Palette.statusForeground(self)
    }

    /// The badge shows a check in the success color in place of its
    /// letter: a resolved conflict, where the theme's badge is a square.
    var showsCheck: Bool {
        self == .resolved && ChangesThemeStyle.current.statusBadge == .square
    }
}

/// A file's status badge, as the theme draws it: its letter in the status
/// color, bold, on a rounded square of the status's tint. A tile is 20
/// points on a side in rows, its letter in the code font; a square is 17,
/// its letter in the system's monospaced font, and shows a resolved
/// conflict as a green check. Beside the diff's file name it's 24; the
/// radius and the letter scale with it.
public struct StatusGlyph: View {
    private let kind: FileStatusKind
    private let side: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast

    /// - Parameter size: The side; nil for the rows' size.
    public init(_ kind: FileStatusKind, size: CGFloat? = nil) {
        self.kind = kind
        side = size
    }

    public var body: some View {
        let side = side ?? Metrics.StatusTile.size
        let scale = side / Metrics.StatusTile.size
        Group {
            if kind.showsCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Metrics.StatusTile.checkSize * scale))
                    .foregroundStyle(Color(espalier: Palette.success))
                    .frame(width: side, height: side)
            } else {
                Text(kind.letter)
                    .font(letterFont(scale: scale))
                    .foregroundStyle(Color(espalier: kind.tileInk))
                    .frame(width: side, height: side)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.StatusTile.radius * scale, style: .continuous)
                            .fill(Color(espalier: kind.tileFill))
                    )
            }
        }
        .tooltip(kind.title)
        .accessibilityLabel(kind.title)
    }

    /// The letter's font: as `Metrics.StatusTile.letterFont`.
    private func letterFont(scale: CGFloat) -> Font {
        let size = Metrics.StatusTile.letterSize * scale
        let increased = contrast == .increased
        if ChangesThemeStyle.current.statusBadge == .square {
            return .system(size: size, weight: increased ? .heavy : .bold, design: .monospaced)
        }
        return Typography.mono(size: size, weight: increased ? .black : .bold)
    }
}

extension Metrics {
    /// A file's status badge: a rounded square of the status's tint with
    /// its letter, a tile or a square as the theme has it
    /// (`ChangesThemeStyle.statusBadge`).
    public enum StatusTile {
        private static var isSquare: Bool {
            ChangesThemeStyle.current.statusBadge == .square
        }

        /// The side in rows.
        public static var size: CGFloat {
            isSquare ? 17 : 20
        }

        /// Beside the diff's file name.
        public static let header: CGFloat = 24

        public static var radius: CGFloat {
            isSquare ? 6 : 6.5
        }

        /// The letter's point size.
        public static var letterSize: CGFloat {
            isSquare ? 9.5 : 11
        }

        /// A resolved conflict's check's point size, on a square.
        static let checkSize: CGFloat = 13

        /// The tint's alpha, light and dark.
        public static var tint: (light: CGFloat, dark: CGFloat) {
            isSquare ? (0.15, 0.15) : (0.2, 0.28)
        }

        /// The letter's font at `scale` of the rows' size: bold (black with
        /// Increase Contrast) in the code font on a tile; bold (heavy) in
        /// the system's monospaced font on a square.
        static func letterFont(scale: CGFloat = 1, increasedContrast: Bool) -> NSFont {
            let size = letterSize * scale
            if isSquare {
                return FontFallback.checked(.monospacedSystemFont(ofSize: size, weight: increasedContrast ? .heavy : .bold), size: size, design: .mono)
            }
            return AppKitTypography.mono(size: size, weight: increasedContrast ? .black : .bold)
        }
    }
}

/// The overall state of a pull request's checks.
nonisolated public enum ChecksState: String, CaseIterable, Sendable {
    case success, failure, pending, neutral

    /// A distinct shape per state: the checks list's shapes, a minus for
    /// checks that ended neither passed nor failed.
    public var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .neutral: "minus.circle.fill"
        }
    }

    /// The state in words.
    public var title: String {
        switch self {
        case .success: "Successful"
        case .failure: "Failed"
        case .pending: "Pending"
        case .neutral: "Neutral"
        }
    }
}

/// The glyph of a checks state.
public struct ChecksGlyph: View {
    private let state: ChecksState

    public init(_ state: ChecksState) {
        self.state = state
    }

    public var body: some View {
        Image(systemName: state.systemImage)
            .foregroundStyle(Color(espalier: Palette.checks(state)))
            .accessibilityLabel("Checks: \(state.title)")
    }
}

/// The warning glyph: conflicts, background failures.
public struct WarningGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Color(espalier: Palette.warningMark))
            .accessibilityLabel("Warning")
    }
}

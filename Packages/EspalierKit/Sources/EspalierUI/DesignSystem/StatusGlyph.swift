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
    /// The tile's fill: a tint of the status color.
    public var tileFill: NSColor {
        Palette.tint(color, light: Metrics.StatusTile.tint.light, dark: Metrics.StatusTile.tint.dark)
    }

    /// The tile's letter: the status's own foreground.
    public var tileInk: NSColor {
        Palette.statusForeground(self)
    }
}

/// A file's status tile: its letter in the status color, bold, in the code font, on a
/// rounded square of the status's tint, 20 points on a side in rows and
/// 24 beside the diff's file name; the radius and the letter scale with it.
public struct StatusGlyph: View {
    private let kind: FileStatusKind
    private let side: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ kind: FileStatusKind, size: CGFloat = Metrics.StatusTile.size) {
        self.kind = kind
        side = size
    }

    public var body: some View {
        let scale = side / Metrics.StatusTile.size
        Text(kind.letter)
            .font(Typography.mono(size: Metrics.StatusTile.letterSize * scale, weight: contrast == .increased ? .black : .bold))
            .foregroundStyle(Color(espalier: kind.tileInk))
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: Metrics.StatusTile.radius * scale, style: .continuous)
                    .fill(Color(espalier: kind.tileFill))
            )
            .tooltip(kind.title)
            .accessibilityLabel(kind.title)
    }
}

extension Metrics {
    /// A file's status tile: a rounded square of the status's tint with its
    /// letter.
    public enum StatusTile {
        public static let size: CGFloat = 20
        /// Beside the diff's file name.
        public static let header: CGFloat = 24
        public static let radius: CGFloat = 6.5
        /// The letter's point size.
        public static let letterSize: CGFloat = 11
        /// The tint's alpha, light and dark.
        public static let tint: (light: CGFloat, dark: CGFloat) = (0.2, 0.28)
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

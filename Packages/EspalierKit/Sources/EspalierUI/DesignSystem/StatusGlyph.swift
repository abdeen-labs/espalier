// The file status badge and the checks glyphs. A file's status is a letter
// (A, M, D, R, C, U); checks use distinct shapes.

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

    /// The letter in the glyph.
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

/// A file's status badge: its letter in the status color on a 15% tint, in
/// a 17-point square with radius 6 (Classic's; a theme can fill it with the
/// status color, and make it a circle).
public struct StatusGlyph: View {
    private let kind: FileStatusKind
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ kind: FileStatusKind) {
        self.kind = kind
    }

    public var body: some View {
        Text(kind.letter)
            .font(.system(size: 9.5, weight: contrast == .increased ? .heavy : .bold, design: .monospaced))
            .foregroundStyle(Color(espalier: Palette.statusForeground(kind)))
            .frame(width: Metrics.StatusBadge.size, height: Metrics.StatusBadge.size)
            .background(
                RoundedRectangle(cornerRadius: Metrics.StatusBadge.radius, style: .continuous)
                    .fill(Color(espalier: Palette.statusBackground(kind)))
            )
            .tooltip(kind.title)
            .accessibilityLabel(kind.title)
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

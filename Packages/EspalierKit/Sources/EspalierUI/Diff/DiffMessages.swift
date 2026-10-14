// Ported from desktop/app/src/ui/diff/diff-contents-warning.tsx
//
// The warnings above a text diff (hidden bidirectional Unicode characters,
// line endings Git will convert) and the popover that offers to show
// whitespace changes when a hidden-whitespace diff's gutter is clicked.

import GitKit
import SwiftUI

/// A warning about a text diff's contents.
nonisolated enum DiffContentsWarning: Sendable, Equatable, Hashable {
    /// The diff has invisible bidirectional Unicode characters.
    case unicodeBidiCharacters
    /// Git will change the file's line endings: to LF as it commits the
    /// file, to CRLF as it checks the file out.
    case lineEndingsChange(LineEndingsChange)

    /// The warnings for a text diff: hidden bidirectional characters, then
    /// line endings.
    static func warnings(for diff: any TextDiffData) -> [DiffContentsWarning] {
        var warnings: [DiffContentsWarning] = []
        if diff.hasHiddenBidiChars {
            warnings.append(.unicodeBidiCharacters)
        }
        if let change = diff.lineEndingsChange {
            warnings.append(.lineEndingsChange(change))
        }
        return warnings
    }

    var message: String {
        switch self {
        case .unicodeBidiCharacters:
            "This diff contains bidirectional Unicode text that may be interpreted or compiled differently than what appears below. To review, open the file in an editor that reveals hidden Unicode characters."
        case .lineEndingsChange(let change) where change.to == .lf:
            "This file uses '\(change.from.rawValue)' line endings, but Git is configured to commit them as '\(change.to.rawValue)'."
        case .lineEndingsChange(let change):
            "This file uses '\(change.from.rawValue)' line endings, but Git is configured to convert them to '\(change.to.rawValue)' the next time the file is checked out."
        }
    }
}

/// The warnings above a text diff, on a band tinted with the warning
/// color (as an operation's bar is).
struct DiffMessages: View {
    let warnings: [DiffContentsWarning]

    /// The band: the modified color at 7%.
    static var background: NSColor { Palette.tint(Palette.modified, light: 0.07, dark: 0.07) }

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                ForEach(warnings, id: \.self) { warning in
                    Label {
                        Text(warning.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: Palette.warning))
                    }
                    .font(Typography.secondary)
                }
            }
            .padding(.horizontal, Metrics.insetMedium)
            .padding(.vertical, Metrics.insetSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: DiffMessages.background))
            .overlay(alignment: .bottom) {
                Hairline()
            }
        }
    }
}

/// "Show whitespace changes?": offered when the gutter of a diff hiding
/// whitespace changes is clicked, since lines can't be selected then.
struct WhitespaceHintView: View {
    let onCancel: () -> Void
    let onShow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Text("Show whitespace changes?")
                .font(Typography.heading)
            Text("Selecting lines is disabled when hiding whitespace changes.")
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Show Whitespace", action: onShow)
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(Metrics.insetMedium)
        .frame(width: 260)
    }
}

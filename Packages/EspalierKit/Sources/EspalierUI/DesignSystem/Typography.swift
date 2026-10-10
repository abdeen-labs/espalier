// Espalier's type roles. SF Pro and SF Mono at the system's sizes: body 13,
// secondary 12, meta 11.5; SF Mono 11 for code, commit IDs, counts, and
// ahead and behind arrows. Roles at a system text style's size use the
// style, so the macOS Text Size setting applies.

import AppKit
import SwiftUI

/// Espalier's fonts, for SwiftUI.
public enum Typography {
    /// List rows and body text (13).
    public static let row: Font = .body
    /// Secondary text in rows and headers (12).
    public static let secondary: Font = .callout
    /// Smaller secondary text (11).
    public static let subheadline: Font = .subheadline
    /// Meta lines: "Maya Chen · 12 min ago · 4 files" (11.5).
    public static let meta: Font = .system(size: 11.5)
    /// A commit's title in its details (15, semibold).
    public static let commitSummary: Font = .title3.weight(.semibold)
    /// Headings inside panes and sheets.
    public static let heading: Font = .headline
    /// A Settings pane's name in its header band (13.5, semibold).
    public static let paneTitle: Font = .system(size: 13.5, weight: .semibold)
    /// A Settings row's title (13, medium).
    public static let rowTitle: Font = .body.weight(.medium)
    /// Sidebar section labels (10.5, semibold): use `SectionLabel`, which
    /// adds the uppercase and the tracking.
    public static let sectionLabel: Font = .system(size: 10.5, weight: .semibold)
    /// A section label's count ("BRANCHES 5"), in SF Mono.
    public static let sectionCount: Font = .system(size: 10.5, weight: .medium, design: .monospaced)
    /// The tracking of section labels: 0.07 em.
    public static let sectionLabelTracking: CGFloat = 10.5 * 0.07
    /// Ref tags: SF Mono 10.5, semibold.
    public static let refCapsule: Font = .system(size: 10.5, weight: .semibold, design: .monospaced)
    /// "+N" and other tiny counts.
    public static let tinyCount: Font = .system(size: 10.5, weight: .medium, design: .monospaced)
    /// Counts in rows and headers (SF Mono 11).
    public static let count: Font = .system(size: 11, weight: .medium, design: .monospaced)
    /// Secondary counts ("↑2 ↓3"), in SF Mono.
    public static let secondaryCount: Font = .system(size: 11, weight: .medium, design: .monospaced)
    /// The ahead count in the accent ("↑2"), semibold.
    public static let aheadCount: Font = .system(size: 11, weight: .semibold, design: .monospaced)
    /// SHAs in text (SF Mono 11).
    public static let sha: Font = .system(size: 11, design: .monospaced)
    /// Terminal output (hooks, raw git errors).
    public static let terminal: Font = .system(size: 11, design: .monospaced)
    /// Key caps' text (10.5).
    public static let keyCap: Font = .system(size: 10.5, weight: .medium)
    /// Quiet and secondary buttons' titles (13, medium; 12 when small).
    public static let button: Font = .body.weight(.medium)
    /// Prominent buttons' titles (13, semibold).
    public static let prominentButton: Font = .body.weight(.semibold)
    /// Small buttons' titles (12, medium).
    public static let smallButton: Font = .callout.weight(.medium)
    /// Small prominent buttons' titles (12, semibold).
    public static let smallProminentButton: Font = .callout.weight(.semibold)

    /// Code at the user's code text size (⌘= / ⌘− / ⌘0).
    public static func code(size: CGFloat = Metrics.Diff.codeFontSize) -> Font {
        .system(size: size, design: .monospaced)
    }
}

/// Espalier's fonts, for AppKit views (the graph and diff tables).
public enum AppKitTypography {
    /// List rows (13 pt at the default text size).
    public static var row: NSFont {
        .preferredFont(forTextStyle: .body)
    }

    /// Secondary text in rows.
    public static var secondary: NSFont {
        .preferredFont(forTextStyle: .callout)
    }

    /// Ref tags: SF Mono 10.5, semibold.
    public static var refCapsule: NSFont {
        .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    }

    /// "+N" counts.
    public static var tinyCount: NSFont {
        .monospacedSystemFont(ofSize: 10.5, weight: .medium)
    }

    /// Code at a size.
    public static func code(size: CGFloat = Metrics.Diff.codeFontSize, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Counts in SF Mono.
    public static func count(size: CGFloat = 11) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .medium)
    }

    /// A commit ID typed into a field (Go to Commit): SF Mono at a field's
    /// text size, the body's (13).
    public static var shaField: NSFont {
        .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
    }
}

/// A sidebar section label: uppercase, 10.5 semibold with 0.07 em
/// tracking, and its count in SF Mono ("BRANCHES 5").
public struct SectionLabel: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionLabelTracking)
                .textCase(.uppercase)
            if let count {
                Text("\(count)")
                    .font(Typography.sectionCount)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.text3)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isHeader)
    }
}

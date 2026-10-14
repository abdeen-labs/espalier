// How a file row shares its room among its labels (the name, then a
// rename's source, then the folder): each whole while they fit; the last
// cut first; a label cut narrower than its shortest truncation (its first
// character, "…", and its last) left out with its gap; the name cut only
// once nothing after it shows. History's rows lay out with
// `FileLabelLayout`, the Changes table's (`FileRowView`) with the widths
// directly.

import AppKit
import SwiftUI

/// The widths of a file row's labels.
nonisolated enum FileLabelWidths {
    /// Each label's width in `room`, in order.
    ///
    /// - Parameters:
    ///   - natural: Each label's whole width; the first is the name.
    ///   - floors: The narrowest each label can be cut to and still read
    ///     (`floor(of:font:)`); narrower, it leaves.
    ///   - room: The width the labels share.
    ///   - gap: The space between two labels that show.
    /// - Returns: Each label's width; 0 for one that leaves. The name never
    ///   leaves: it takes what's left, down to 0.
    static func widths(natural: [CGFloat], floors: [CGFloat], room: CGFloat, gap: CGFloat) -> [CGFloat] {
        var widths = natural
        var overflow = natural.reduce(0, +) + gap * CGFloat(max(natural.count - 1, 0)) - max(room, 0)
        for index in natural.indices.dropFirst().reversed() where overflow > 0 {
            let cut = widths[index] - overflow
            if cut >= min(floors[index], natural[index]) {
                widths[index] = cut
                overflow = 0
            } else {
                overflow -= widths[index] + gap
                widths[index] = 0
            }
        }
        if overflow > 0, !widths.isEmpty {
            widths[0] = max(widths[0] - overflow, 0)
        }
        return widths
    }

    /// The width of `text`'s shortest truncation in `font`: its first
    /// character, "…", and its last, or the whole text when that's
    /// narrower.
    @MainActor
    static func floor(of text: String, font: NSFont) -> CGFloat {
        guard let first = text.first, let last = text.last, text.count > 2 else {
            return width(of: text, font: font)
        }
        return min(width(of: "\(first)\u{2026}\(last)", font: font), width(of: text, font: font))
    }

    @MainActor
    private static func width(of text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
}

/// A label's shortest truncation, for `FileLabelLayout`.
nonisolated struct FileLabelFloor: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// A file's labels on one line, centered vertically, sharing the width
/// they're given as `FileLabelWidths` says. A label that leaves goes past
/// the trailing edge, which the layout's view clips (`.clipped()`): a text
/// given no width can still draw "…".
struct FileLabelLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let whole = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width.map { min($0, whole) } ?? whole
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = FileLabelWidths.widths(
            natural: subviews.map { $0.sizeThatFits(.unspecified).width },
            floors: subviews.map { $0[FileLabelFloor.self] },
            room: bounds.width,
            gap: spacing
        )
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            guard width > 0 else {
                subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .leading, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

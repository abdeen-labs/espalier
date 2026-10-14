// Draws columns of history graph rows for captures, and lays out
// histories written as text. The graph is pure drawing, so it's drawn
// straight into a 2x bitmap; the table goes through `Capture.render` like
// every other view.

import AppKit
import EspalierCore
@testable import EspalierUI

/// One row of a graph capture.
struct GraphCaptureRow {
    var drawing: GraphRowDrawing
    var emphasis = GraphEmphasis()
    var label: String
    var isSelected = false
}

/// Draws graph rows into bitmaps.
@MainActor
enum GraphCapture {
    /// The scale the rows are drawn at.
    static let scale: CGFloat = Capture.scale
    /// The space for the labels right of the graph.
    static let labelWidth: CGFloat = 150

    /// The track colors, with an accent that doesn't depend on the Mac's
    /// settings.
    static let palette = TrackPalette.Resolved(accent: .systemBlue)

    /// The rows of a whole layout, labeled with their commits' names and
    /// stubs.
    static func rows(
        _ layout: CommitGraphLayout,
        commits: [CommitGraphCommit],
        headSHA: String?,
        workingCopyIsDirty: Bool = true
    ) -> [GraphCaptureRow] {
        let offset = layout.hasUncommittedWorkRow ? 1 : 0
        let headRow = headSHA.flatMap { head in commits.firstIndex { $0.sha == head } }.map { $0 + offset }
        func name(_ row: Int) -> String {
            row < offset ? "Uncommitted changes" : commits[row - offset].sha
        }
        return layout.indices.map { index in
            let commit = index >= offset ? commits[index - offset] : nil
            var notes = ""
            for edge in layout[index].edges {
                switch edge.kind {
                case .outgoingStub: notes += " v " + (edge.parentRow.map(name) ?? "?")
                case .incomingStub: notes += " ^ " + (edge.childRow.map(name) ?? "?")
                case .unrouted: notes += " (parent " + (edge.parentRow.map(name) ?? "?") + " above)"
                default: break
                }
            }
            return GraphCaptureRow(
                drawing: GraphRowDrawing(
                    layout: layout,
                    row: index,
                    isMerge: (commit?.parentSHAs.count ?? 0) > 1,
                    headRow: headRow,
                    hasHead: headSHA != nil,
                    workingCopyIsDirty: workingCopyIsDirty
                ),
                label: name(index) + notes
            )
        }
    }

    /// Draws `rows` one under the other, each with its label right of the
    /// graph, on the row background; selected rows on the selection color.
    static func render(_ rows: [GraphCaptureRow], geometry: GraphGeometry, appearance: CaptureAppearance) -> NSBitmapImageRep {
        let width = geometry.columnWidth + labelWidth
        let height = CGFloat(max(rows.count, 1)) * geometry.rowHeight
        let pixelsWide = Int((width * scale).rounded(.up))
        let pixelsHigh = Int((height * scale).rounded(.up))
        let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        appearance.appearance.performAsCurrentDrawingAppearance {
            let colors = GraphColors(palette: palette, appearance: appearance.appearance)
            Palette.background.setFill()
            CGRect(x: 0, y: 0, width: width, height: height).fill()
            for (index, row) in rows.enumerated() {
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(index) * geometry.rowHeight)
                // Each row draws in its own band, as table cells do.
                context.clip(to: CGRect(x: 0, y: 0, width: width, height: geometry.rowHeight))
                var emphasis = row.emphasis
                if row.isSelected {
                    // The selection's soft tint behind the row (the rings fill with it).
                    Palette.accentSoft.setFill()
                    CGRect(x: 0, y: 0, width: width, height: geometry.rowHeight).fill()
                    emphasis.isSelected = true
                }
                GraphRenderer.draw(row.drawing, emphasis: emphasis, geometry: geometry, colors: colors, numberFormat: Capture.numberFormat, in: context)
                let text = NSAttributedString(string: row.label, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: Palette.text,
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: geometry.columnWidth + 4, y: (geometry.rowHeight - size.height) / 2))
                context.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        rep.size = CGSize(width: width, height: height)
        return rep
    }
}

/// Parses a history: one commit per line, its name and then its parents'.
func graphCommits(_ text: String) -> [CommitGraphCommit] {
    text.split(separator: "\n").compactMap { line in
        let words = line.split(separator: " ").map(String.init)
        guard let sha = words.first else {
            return nil
        }
        return CommitGraphCommit(sha: sha, parentSHAs: Array(words.dropFirst()))
    }
}

/// Lays out a whole history.
func graphLayout(_ commits: [CommitGraphCommit], _ options: CommitGraphOptions) -> CommitGraphLayout {
    var builder = CommitGraphBuilder(options: options)
    builder.append(commits)
    builder.finish()
    return builder.layout
}

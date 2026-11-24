// The diff's header: the file's name and folder (after its status tile,
// the name in bold, where the theme shows the tile; else the status is the
// path's tooltip), a rename's or copy's "old → new" line, the added and
// removed line counts, Open in <Editor>, and the options menu. Unified and
// Split are in the options menu (and the View menu); an image diff's modes
// are above its images. The counts roll over
// 0.2 s as the same file's diff reloads; another file's show at once.

import EspalierCore
import GitKit
import SwiftUI

/// What the header shows.
nonisolated struct DiffHeaderContent: Sendable, Equatable {
    var path: String
    /// A rename's or copy's old path.
    var oldPath: String?
    var status: FileStatusKind
    /// "+12 −4", for a text diff that shows.
    var addedLines: Int?
    var deletedLines: Int?
    /// "Open in <Editor>", when the file can be opened.
    var openInEditorTitle: String?

    /// The file's name.
    var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// The folder the file is in, or "" at the root.
    var directory: String {
        (path as NSString).deletingLastPathComponent
    }
}

/// The diff's header row: the status tile and the name in bold, or the name
/// alone, by theme; the folder in tertiary text, the counts (zero counts
/// left out), Open in <Editor>, and the options.
struct DiffHeader<Options: View>: View {
    let content: DiffHeaderContent
    var openInEditor: @MainActor () -> Void = {}
    @ViewBuilder var options: () -> Options
    @Environment(\.motion) private var motion

    /// The row's height on one line: the pane headers', so their
    /// hairlines line up.
    static var height: CGFloat {
        Metrics.PaneHeader.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.insetSmall) {
                path
                Spacer(minLength: Metrics.insetSmall)
                stats
                HStack(spacing: 0) {
                    if let title = content.openInEditorTitle {
                        Button(action: openInEditor) {
                            Label(title, systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.icon)
                        .tooltip(title)
                        .accessibilityLabel(title)
                    }
                    options()
                }
            }
            .frame(minHeight: Self.height)
            if let oldPath = content.oldPath {
                Text("\(oldPath) \u{2192} \(content.path)")
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tooltip("\(oldPath) \u{2192} \(content.path)")
                    .padding(.leading, showsTile ? Metrics.StatusTile.header + Metrics.insetSmall : 0)
                    .padding(.bottom, Metrics.insetSmall)
            }
        }
        .padding(.leading, Metrics.insetMedium)
        .padding(.trailing, Metrics.insetSmall)
    }

    private var showsTile: Bool {
        Theme.current.style.diff.fileHeader == .tile
    }

    private var path: some View {
        HStack(spacing: Metrics.insetSmall) {
            if showsTile {
                StatusGlyph(content.status, size: Metrics.StatusTile.header)
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                Text(content.fileName)
                    .font(showsTile ? Typography.paneHeading : Typography.row.weight(.medium))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !content.directory.isEmpty {
                    Text(content.directory)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .tooltip(showsTile ? nil : content.status.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.path), \(content.status.title)")
    }

    @ViewBuilder
    private var stats: some View {
        if let added = content.addedLines, let deleted = content.deletedLines, added + deleted > 0 {
            LineCountPills(added: added, deleted: deleted)
                .contentTransition(motion.animates ? .numericText() : .identity)
                .motion(Motion.kindChange, value: [added, deleted])
                .padding(.trailing, Metrics.grid)
        }
    }
}

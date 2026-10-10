// The diff's header: the file name and folder, a rename's "old → new"
// line, the added and removed line counts, Open in <Editor>, and the
// options menu. Unified and Split are in the options menu (and the View
// menu); an image diff's modes are above its images.

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

/// The diff's header row: the name, the folder in tertiary text, the counts
/// in SF Mono, Open in <Editor>, and the options.
struct DiffHeader<Options: View>: View {
    let content: DiffHeaderContent
    var openInEditor: @MainActor () -> Void = {}
    @ViewBuilder var options: () -> Options

    /// The row's height on one line.
    static var height: CGFloat {
        40
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
                        .help(title)
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
                    .help("\(oldPath) \u{2192} \(content.path)")
                    .padding(.bottom, Metrics.insetSmall)
            }
        }
        .padding(.leading, Metrics.insetMedium)
        .padding(.trailing, Metrics.insetSmall)
    }

    private var path: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Text(content.fileName)
                .font(Typography.row.weight(.medium))
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
        .help(content.status.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.path), \(content.status.title)")
    }

    @ViewBuilder
    private var stats: some View {
        if let added = content.addedLines, let deleted = content.deletedLines, added + deleted > 0 {
            HStack(spacing: Metrics.grid) {
                Text("+\(added)")
                    .foregroundStyle(Color(nsColor: DiffColors.addedMarker))
                Text("\u{2212}\(deleted)")
                    .foregroundStyle(Color(nsColor: DiffColors.deletedMarker))
            }
            .font(Typography.count)
            .padding(.trailing, Metrics.grid)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(added) added, \(deleted) removed")
        }
    }
}

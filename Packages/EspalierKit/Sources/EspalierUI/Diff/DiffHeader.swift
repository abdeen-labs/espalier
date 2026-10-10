// The diff's header: the file name and folder, a rename's "old → new"
// line, the added and removed line counts, Unified/Split (or an image
// diff's four modes), Open in <Editor>, and the options menu.

import EspalierCore
import GitKit
import SwiftUI

/// What the header shows.
nonisolated struct DiffHeaderContent: Sendable, Equatable {
    /// How the diff can be shown.
    enum Mode: Sendable, Equatable {
        /// A text diff: unified or split.
        case text(isSplit: Bool)
        /// A modified image: one of the four modes.
        case image(ImageDiffType)
        /// Nothing to switch (binary, submodule, large, or loading).
        case none
    }

    var path: String
    /// A rename's or copy's old path.
    var oldPath: String?
    var status: FileStatusKind
    /// "+12 −4", for text diffs.
    var addedLines: Int?
    var deletedLines: Int?
    var mode: Mode
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
/// in SF Mono, Unified | Split (or an image diff's four modes) as the
/// capsule segmented control, Open in <Editor>, and the options.
struct DiffHeader<Options: View>: View {
    let content: DiffHeaderContent
    var setSplit: @MainActor (Bool) -> Void = { _ in }
    var setImageMode: @MainActor (ImageDiffType) -> Void = { _ in }
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
                modeControl
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
        .padding(.leading, Metrics.insetMedium + 2)
        .padding(.trailing, Metrics.insetSmall)
    }

    private var path: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.grid + 2) {
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
            HStack(spacing: Metrics.grid + 1) {
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

    @ViewBuilder
    private var modeControl: some View {
        switch content.mode {
        case .text(let isSplit):
            CapsuleSegmentedControl(
                "Diff Display",
                selection: Binding(get: { isSplit }, set: setSplit),
                segments: [
                    CapsuleSegment("Unified", value: false),
                    CapsuleSegment("Split", value: true),
                ]
            )
            .fixedSize()
            .help(isSplit ? "Split" : "Unified")
        case .image(let mode):
            CapsuleSegmentedControl(
                "Image Diff",
                selection: Binding(get: { mode }, set: setImageMode),
                segments: ImageDiffType.allModes.map { CapsuleSegment($0.title, value: $0) }
            )
            .fixedSize()
        case .none:
            EmptyView()
        }
    }
}

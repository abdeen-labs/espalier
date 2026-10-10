// A Markdown document's blocks, laid out. Text is selectable; links open in
// the browser through the window's integrations; images load through the
// window's image loader, and show as links until they load or when they
// can't (trying again when the network comes back).

import EspalierCore
import SwiftUI

/// A parsed Markdown document.
struct MarkdownView: View {
    let document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(document.blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One block: indented for its lists, with a bar per quote.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.quaternary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
            content
                .foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, CGFloat(block.indent) * Metrics.insetLarge)
    }

    @ViewBuilder
    private var content: some View {
        switch block.content {
        case .text(let text, let level):
            Text(text)
                .font(Self.font(headingLevel: level))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(level == nil ? [] : .isHeader)

        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: Metrics.grid + 2) {
                MarkdownListMarker(marker: marker)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code, _):
            ScrollView(.horizontal) {
                Text(code)
                    .font(Typography.code())
                    .fixedSize()
                    .padding(Metrics.insetSmall)
            }
            .scrollIndicators(.never)
            .background(Color(espalier: Palette.field), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)

        case .image(let image):
            MarkdownImageView(image: image)

        case .rule:
            Hairline()
                .padding(.vertical, Metrics.grid)
        }
    }

    /// Headings stay below the pull request's title (`.title3`).
    private static func font(headingLevel: Int?) -> Font {
        switch headingLevel {
        case nil: Typography.row
        case 1?: .title3.weight(.semibold)
        case 2?: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

/// A list item's bullet, number, or task box.
private struct MarkdownListMarker: View {
    let marker: MarkdownBlock.ListMarker

    var body: some View {
        Group {
            switch marker {
            case .bullet:
                Text("•")
            case .number(let number):
                Text("\(number).")
                    .monospacedDigit()
            case .task(let done):
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .accessibilityLabel(done ? "Done" : "Not done")
            }
        }
        .foregroundStyle(.text2)
        .frame(minWidth: Metrics.insetLarge, alignment: .trailing)
    }
}

/// A table: its header in bold, then its rows.
private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.insetMedium, verticalSpacing: Metrics.grid) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    Text(header[column])
                        .fontWeight(.semibold)
                }
            }
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        Text(rows[row][column])
                    }
                }
            }
        }
        .padding(Metrics.insetSmall)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary)
        }
    }
}

/// An image: loaded by the window's image loader, a placeholder while it
/// loads, and a link to it when it can't be shown.
struct MarkdownImageView: View {
    /// Large screenshots are downsampled to this many pixels wide.
    static let maximumPixels = 2_400

    let image: MarkdownImage
    @Environment(\.avatarLoader) private var loader
    @State private var loaded: CGImage?
    @State private var failed = false
    /// How many times the network came back after it failed.
    @State private var retries = 0

    var body: some View {
        Group {
            if let loaded {
                Image(loaded, scale: 1, label: Text(image.alt))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.width ?? CGFloat(loaded.width), alignment: .leading)
            } else if remote == nil || failed {
                Link(destination: image.url) {
                    Label(image.alt.isEmpty ? image.url.lastPathComponent : image.alt, systemImage: "photo")
                }
                .help(image.url.absoluteString)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(espalier: Palette.field))
                    .frame(width: min(image.width ?? 240, 240), height: 80)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.text3)
                    }
                    .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
            }
        }
        .task(id: ImageKey(url: image.url, retries: retries)) {
            guard let remote else {
                return
            }
            if let cached = remote.cachedImage(at: image.url, maximumPixels: Self.maximumPixels) {
                loaded = cached
                return
            }
            let result = await remote.image(at: image.url, maximumPixels: Self.maximumPixels)
            guard !Task.isCancelled else {
                return
            }
            loaded = result
            failed = result == nil
        }
        .onReceive(NotificationCenter.default.publisher(for: GitHubAvatarLoader.networkDidReturn)) { _ in
            // The network came back: a failed image tries again.
            if failed {
                retries += 1
            }
        }
    }

    private var remote: (any RemoteImageLoading)? {
        loader as? any RemoteImageLoading
    }

    private struct ImageKey: Hashable {
        let url: URL
        let retries: Int
    }
}

extension EnvironmentValues {
    /// Parses pull request descriptions on the main actor, so a snapshot
    /// renders them at once (they're parsed off it otherwise).
    @Entry var markdownParsesSynchronously = false
}

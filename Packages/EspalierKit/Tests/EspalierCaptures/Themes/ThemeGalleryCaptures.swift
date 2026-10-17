// A compact gallery of what the themes and fonts change, in light and
// dark: the sidebar with its selection and a section label, a few graph
// rows, two History rows with ref tags (one selected), the buttons, a
// commit's title, and file badges. Each theme in each of its colors, each
// background tint on Classic, Classic's backgrounds on Islands, and each app
// font and code font on Classic.

import AppKit
import EspalierCore
import GitHubKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Theme gallery", .captures) @MainActor
struct ThemeGalleryCaptures {
    private let area = "Themes"

    @Test("each theme in each of its colors", arguments: DesignTheme.allCases.flatMap { theme in
        theme.colors.isEmpty ? [Look(theme: theme)] : theme.colors.map { Look(theme: theme, color: $0) }
    })
    func themes(_ look: Look) {
        capture(ThemeGallery(), named: "gallery", area: area, look: look)
    }

    @Test("each background tint on Classic", arguments: DesignTheme.classic.backgrounds.filter { $0 != .own })
    func backgrounds(_ background: BackgroundTint) {
        capture(ThemeGallery(), named: "gallery", area: area, look: Look(background: background))
    }

    @Test("Classic's backgrounds on Islands")
    func islandsClassicBackgrounds() {
        capture(ThemeGallery(), named: "gallery", area: area, look: Look(theme: .islands, background: .classic))
    }

    @Test("each app font on Classic", arguments: [AppFont.fixel, .atkinson, .martian])
    func appFonts(_ font: AppFont) {
        capture(ThemeGallery(), named: "gallery", area: area, look: Look(appFont: font))
    }

    @Test("each code font on Classic", arguments: [CodeFont.geistMono, .atkinsonMono])
    func codeFonts(_ font: CodeFont) {
        capture(ThemeGallery(), named: "gallery", area: area, look: Look(codeFont: font))
    }
}

/// The gallery: a sidebar beside a History-like column.
struct ThemeGallery: View {
    var body: some View {
        let palette = TrackPalette.Resolved(currentTrack: 0, branchColors: BranchColors(
            branches: ["feature/hourly-forecast", "main", "fix/locale-units"],
            current: "feature/hourly-forecast",
            defaultBranch: "main"
        ))
        HStack(alignment: .top, spacing: 0) {
            GallerySidebar()
                .frame(width: 210)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: Palette.sidebar))
            Hairline(.vertical)
            VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                HStack(alignment: .top, spacing: Metrics.insetMedium) {
                    GalleryGraph()
                        .frame(width: GalleryGraph.width, height: GalleryGraph.height)
                    VStack(alignment: .leading, spacing: 2) {
                        GalleryHistoryRow(
                            title: "Show the hourly forecast in the widget",
                            author: "Maya Chen",
                            refs: [RefCapsuleContent(name: "feature/hourly-forecast", kind: .currentBranch, track: 0)],
                            isSelected: true,
                            palette: palette
                        )
                        GalleryHistoryRow(
                            title: "Update German translations",
                            author: "Jonas Berg",
                            refs: [
                                RefCapsuleContent(name: "main", kind: .localBranchWithUpstream(remote: "origin"), track: 1),
                                RefCapsuleContent(name: "v2.4.0", kind: .tag, track: 1),
                            ],
                            isSelected: false,
                            palette: palette
                        )
                    }
                }
                HStack(spacing: Metrics.insetSmall) {
                    Button("Push origin") {}
                        .buttonStyle(.prominent)
                    Button("Fetch") {}
                        .buttonStyle(.quiet)
                    Button("Cancel") {}
                        .buttonStyle(.secondary)
                }
                Text("Show the hourly forecast in the widget")
                    .font(Typography.commitSummary)
                    .foregroundStyle(.text)
                SectionLabel("Changed Files", count: 4)
                HStack(spacing: Metrics.insetMedium) {
                    ForEach([FileStatusKind.modified, .new, .deleted, .renamed], id: \.self) { kind in
                        HStack(spacing: 6) {
                            StatusGlyph(kind)
                            Text(kind.title)
                                .font(Typography.secondary)
                                .foregroundStyle(.text2)
                        }
                    }
                }
                Text("a1b2c3d  ↑2  +38 −6")
                    .font(Typography.sha)
                    .foregroundStyle(.text3)
            }
            .padding(Metrics.insetMedium)
            .frame(width: 520, alignment: .topLeading)
            .background(Color(nsColor: Palette.background))
        }
        .fixedSize()
    }
}

/// The sidebar: Changes and History (selected), and a few branches under
/// their section's label.
private struct GallerySidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(isSelected: false) {
                SidebarRowLabel("Changes", systemImage: "plus.forwardslash.minus") {
                    Text("3")
                        .font(Typography.count)
                        .foregroundStyle(.sidebarRowCount(isSelected: false))
                }
            }
            row(isSelected: true) {
                SidebarRowLabel("History", systemImage: "clock.arrow.circlepath", isSelected: true)
            }
            SectionLabel("Branches")
                .padding(.leading, Metrics.Sidebar.rowInset + Metrics.grid)
                .padding(.top, Metrics.insetMedium)
                .padding(.bottom, Metrics.grid)
            row(isSelected: false) {
                BranchRow(BranchRowContent(ref: "refs/heads/feature/hourly-forecast", name: "feature/hourly-forecast", isCurrent: true, tracking: .aheadBehind(ahead: 2, behind: 0)))
            }
            row(isSelected: false) {
                BranchRow(BranchRowContent(ref: "refs/heads/main", name: "main", isDefault: true))
            }
            row(isSelected: false) {
                BranchRow(BranchRowContent(ref: "refs/heads/fix/locale-units", name: "fix/locale-units", tracking: .aheadBehind(ahead: 0, behind: 11)))
            }
        }
        .padding(.vertical, Metrics.insetSmall)
    }

    /// A sidebar row: 28 high, inset from the sidebar's edges, with the
    /// selection when selected.
    private func row(isSelected: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .environment(\.isSidebarRowSelected, isSelected)
            .padding(.horizontal, Metrics.Sidebar.rowPadding)
            .frame(height: Metrics.RowHeight.sidebar)
            .background {
                if isSelected {
                    SidebarSelectionFill()
                }
            }
            .padding(.horizontal, Metrics.Sidebar.rowInset)
    }
}

/// A History row: the avatar, the ref tags, and the title, selected or
/// not.
private struct GalleryHistoryRow: View {
    let title: String
    let author: String
    let refs: [RefCapsuleContent]
    let isSelected: Bool
    let palette: TrackPalette.Resolved

    var body: some View {
        HStack(spacing: Metrics.CommitRow.spacing) {
            Avatar(AvatarUser(email: "", avatarURL: nil, name: author, endpoint: nil), size: Metrics.CommitRow.rowAvatarSize)
            RefCapsuleList(refs, palette: palette)
            Text(title)
                .font(isSelected ? Typography.row.weight(.semibold) : Typography.row)
                .foregroundStyle(.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.RowHeight.history)
        .selectableRow(isSelected: isSelected, showsSelectionBar: true)
        .frame(width: 380)
    }
}

/// A few rows of the graph: the working copy, HEAD on a branch, a merge,
/// and the default branch.
private struct GalleryGraph: NSViewRepresentable {
    static let width: CGFloat = 70
    static var height: CGFloat { Metrics.Graph.rowHeight * CGFloat(rows.count) }

    static let commits = graphCommits("""
        f2 f1
        f1 m1
        m2 m1 x1
        x1 m1
        m1
        """)
    static let options = CommitGraphOptions(trunkTip: "m2", includesUncommittedWork: true, headSHA: "f2")
    static var rows: [GraphCaptureRow] {
        GraphCapture.rows(graphLayout(commits, options), commits: commits, headSHA: "f2")
    }

    func makeNSView(context: Context) -> GalleryGraphView {
        GalleryGraphView()
    }

    func updateNSView(_ view: GalleryGraphView, context: Context) {}
}

private final class GalleryGraphView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let rows = GalleryGraph.rows
        let layout = graphLayout(GalleryGraph.commits, GalleryGraph.options)
        let geometry = GraphGeometry(rowHeight: Metrics.Graph.rowHeight, laneCount: layout.laneCount)
        let headRow = rows.firstIndex { $0.drawing.node.isCurrentTip }
        let palette = TrackPalette.Resolved(currentTrack: headRow.map { rows[$0].drawing.row.track })
        let colors = GraphColors(palette: palette, appearance: effectiveAppearance)
        for (index, row) in rows.enumerated() {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(index) * geometry.rowHeight)
            context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: geometry.rowHeight))
            GraphRenderer.draw(row.drawing, emphasis: GraphEmphasis(), geometry: geometry, colors: colors, numberFormat: Capture.numberFormat, in: context)
            context.restoreGState()
        }
    }
}

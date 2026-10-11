// Espalier's layout constants. Views take sizes from here, never ad hoc
// numbers.

import AppKit
import SwiftUI

/// Espalier's layout constants.
///
/// Spacing follows a 4-pt grid with 8-, 12-, and 16-pt insets; list rows use
/// the system's metrics.
public enum Metrics {
    /// The grid every spacing is a multiple of.
    public static let grid: CGFloat = 4
    /// Small inset: between related controls.
    public static let insetSmall: CGFloat = 8
    /// Medium inset: inside grouped content.
    public static let insetMedium: CGFloat = 12
    /// Large inset: around a pane's content.
    public static let insetLarge: CGFloat = 16

    /// Corner radii, four of them; controls are capsules.
    public enum Radius {
        /// Checkboxes and key caps.
        public static let small: CGFloat = 5
        /// Every list row: sidebar items, file rows, picker rows, and
        /// History's simple rows.
        public static let row: CGFloat = 9
        /// Cards, banners, action lists, and lists in sheets.
        public static let card: CGFloat = 14
        /// Sheets and popovers.
        public static let sheet: CGFloat = 22
    }

    /// Capsule control heights, by SwiftUI control size: small 26, regular
    /// 28 (sheets, segmented controls), large 32 (the toolbar), extra large
    /// 34 (Commit).
    public enum ControlHeight {
        public static let small: CGFloat = 26
        public static let regular: CGFloat = 28
        public static let toolbar: CGFloat = 32
        public static let large: CGFloat = 34

        /// The height for a control size.
        public static func height(for size: ControlSize) -> CGFloat {
            switch size {
            case .mini, .small: small
            case .regular: regular
            case .large: toolbar
            case .extraLarge: large
            @unknown default: regular
            }
        }

        /// The horizontal padding inside a capsule of a control size.
        public static func horizontalPadding(for size: ControlSize) -> CGFloat {
            switch size {
            case .mini, .small: 12
            case .regular: 12
            case .large, .extraLarge: 13
            @unknown default: 12
            }
        }
    }

    /// Row heights at the default text size.
    public enum RowHeight {
        /// Sidebar items.
        public static let sidebar: CGFloat = 28
        /// File rows in Changes (`FileList.rowHeight` follows the text size).
        public static let file: CGFloat = 30
        /// History rows (`Graph.rowHeight` follows the text size).
        public static let history: CGFloat = 32
    }

    /// The file status badge (M, A, D, R).
    public enum StatusBadge {
        public static let size: CGFloat = 17
        public static let cornerRadius: CGFloat = 6
    }

    /// Checkboxes.
    public enum Checkbox {
        public static let size: CGFloat = 15
    }

    /// Progress: the arc (`ArcProgress`, `ArcProgressView`) and the bar
    /// (`CapsuleProgressBar`), each a mark on a faint track of its own
    /// color. The arc turns, and the bar's segment sweeps, while how far the
    /// work has got isn't known; with a value, they fill as it goes.
    public enum Progress {
        /// One size of the arc: the square it draws in, the radius of the
        /// ring's center line, the stroke, and how much of the ring the
        /// turning arc covers.
        nonisolated public struct ArcSize: Sendable, Equatable {
            public let side: CGFloat
            public let radius: CGFloat
            public let stroke: CGFloat
            public let arc: CGFloat

            /// In a symbol's place: toolbar capsules, sidebar rows, status
            /// glyphs, and the graph's stubs.
            public static let mini = ArcSize(side: 12, radius: 4.5, stroke: 1.5, arc: 0.265)
            /// Beside text.
            public static let small = ArcSize(side: 14, radius: 5.25, stroke: 1.75, arc: 0.265)
            /// Alone, in a pane that's loading: a finer stroke.
            public static let large = ArcSize(side: 28, radius: 11.375, stroke: 2.45, arc: 0.245)
        }

        /// The track's opacity under the arc or the bar's fill.
        nonisolated public static let trackOpacity: CGFloat = 0.18
        /// The bar's height.
        public static let barHeight: CGFloat = 3
        /// An indeterminate bar's sweeping segment, as a fraction of the
        /// bar's width.
        public static let barSegment: CGFloat = 0.3
    }

    /// The window's toolbar: flat, with a hairline below.
    public enum Toolbar {
        public static let height: CGFloat = 52
        /// The search field's width.
        public static let searchWidth: CGFloat = 250
    }

    /// The sidebar.
    public enum Sidebar {
        /// Rows' inset from the sidebar's edges.
        public static let rowInset: CGFloat = 10
        /// Space inside a row before its symbol.
        public static let rowPadding: CGFloat = 8
        /// The branch dot's diameter.
        public static let dotSize: CGFloat = 8
        /// The repository badge's side.
        public static let badgeSize: CGFloat = 18
        /// The repository badge's corner radius.
        public static let badgeCornerRadius: CGFloat = 5
    }

    /// The main window.
    public enum Window {
        public static let defaultWidth: CGFloat = 1280
        public static let defaultHeight: CGFloat = 820
        public static let minimumWidth: CGFloat = 960
        public static let minimumHeight: CGFloat = 600
    }

    /// A column's width limits.
    nonisolated public struct ColumnWidth: Sendable, Equatable {
        public let min: CGFloat
        public let ideal: CGFloat
        /// Nil when the column takes whatever is left.
        public let max: CGFloat?

        public init(min: CGFloat, ideal: CGFloat, max: CGFloat?) {
            self.min = min
            self.ideal = ideal
            self.max = max
        }
    }

    /// Column widths.
    public enum Column {
        public static let sidebar = ColumnWidth(min: 200, ideal: 240, max: 320)
        /// The Changes column (file list and composer), left of the diff.
        public static let changesFileList = ColumnWidth(min: 260, ideal: 320, max: 480)
        /// History's simple list (and a branch's comparison in the simple
        /// style): narrow, as desktop's history list is.
        public static let simpleList = ColumnWidth(min: 260, ideal: 320, max: 480)
        /// History's graph (and a branch's comparison in the graph style).
        /// At the default window its ideal leaves a commit's files and diff
        /// their room.
        public static let graphList = ColumnWidth(min: 320, ideal: 420, max: 900)
        /// The file list inside a commit's detail.
        public static let commitFileList = ColumnWidth(min: 180, ideal: 200, max: 320)
        /// A commit's details never get narrower than their files at their
        /// narrowest beside the diff at its narrowest.
        public static let commitDetailMinimum: CGFloat = commitFileList.min + 1 + diffMinimum
        /// The PR overview, left of the PR's changes (same limits as the graph).
        public static let pullRequestOverview = ColumnWidth(min: 340, ideal: 440, max: 700)
        /// The stash column, left of the stash's diff.
        public static let stashColumn = ColumnWidth(min: 260, ideal: 320, max: 480)
        /// The diff never gets narrower than this.
        public static let diffMinimum: CGFloat = 400
        /// The inspector (History-like places only).
        public static let inspector = ColumnWidth(min: 260, ideal: 300, max: 380)
    }

    /// The history graph.
    public enum Graph {
        /// The row height: `ceil(lineHeight(.body) × 2)`, 32 at the default
        /// text size.
        public static var rowHeight: CGFloat {
            rowHeight(for: NSFont.preferredFont(forTextStyle: .body))
        }

        /// The row height for a body font.
        public static func rowHeight(for font: NSFont) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: font) * 2)
        }

        /// Lane pitch P.
        public static let lanePitch: CGFloat = 16
        /// The pitch past `maxUncompressedLanes` lanes.
        public static let compressedLanePitch: CGFloat = 9
        public static let maxUncompressedLanes = 12
        /// Space left of lane 0; lane x = leadingInset + P·lane + P/2, so
        /// lane 0 sits 20 points in.
        public static let leadingInset: CGFloat = 12
        /// Space right of the last lane.
        public static let trailingInset: CGFloat = 6
        public static let minimumColumnWidth: CGFloat = 36
        public static let maximumColumnWidth: CGFloat = 186
        /// A commit is a ring: the radius of the stroke's center line, and
        /// the stroke.
        public static let nodeRadius: CGFloat = 5.25
        public static let nodeStroke: CGFloat = 3
        /// A merge commit is a small ring.
        public static let mergeNodeRadius: CGFloat = 3.5
        public static let mergeNodeStroke: CGFloat = 2.5
        /// The current tip is a bold ring with a dot in it.
        public static let headNodeRadius: CGFloat = 7.5
        public static let headNodeStroke: CGFloat = 3.25
        public static let headDotRadius: CGFloat = 2.75
        /// Nodes shrink by this much past `maxUncompressedLanes` lanes, so a
        /// ring stays clear of the lines beside it.
        public static let compressedNodeScale: CGFloat = 0.65
        /// Lines are 3 points with round caps and joins, the trunk's and the
        /// branches' alike.
        public static let trackStroke: CGFloat = 3
        /// Added to every stroke under Increase Contrast.
        public static let increaseContrastStroke: CGFloat = 0.5
        /// A line changing lanes runs on a short diagonal centered on the
        /// boundary between two rows; each row holds this fraction of the
        /// row height of it (9 of 32 points).
        public static let bendFraction: CGFloat = 0.28
        /// A stub's length and the part of it that fades.
        public static let stubLength: CGFloat = 9
        public static let stubFadeLength: CGFloat = 5
        /// The chevron at a stub's end, and its opacity.
        public static let stubChevron: CGFloat = 3
        public static let stubChevronOpacity: CGFloat = 0.6
        /// The hit area at a stub's end.
        public static let stubHitArea: CGFloat = 12

        /// The x of a lane's center.
        public static func laneX(_ lane: Int, pitch: CGFloat = lanePitch) -> CGFloat {
            leadingInset + pitch * CGFloat(lane) + pitch / 2
        }

        /// The graph column's width for the widest row seen so far.
        public static func columnWidth(lanes: Int) -> CGFloat {
            let pitch = lanes > maxUncompressedLanes ? compressedLanePitch : lanePitch
            let width = leadingInset + pitch * CGFloat(max(lanes, 1)) + trailingInset
            return min(max(width, minimumColumnWidth), maximumColumnWidth)
        }
    }

    /// History's commit rows, the graph's and the simple list's alike: the
    /// avatar, the ref tags before the title, the unpushed arrow after it,
    /// and the time ("12m", "Oct 5") in its column; the graph adds the short
    /// ID. Rows draw their selection inset from the list's sides.
    public enum CommitRow {
        /// The default avatar size of `Avatar`.
        public static let avatarSize: CGFloat = 16
        /// The avatar in History's rows.
        public static let rowAvatarSize: CGFloat = 20
        /// The space between a row's parts.
        public static let spacing: CGFloat = 10
        /// Space after the last part.
        public static let trailingPadding: CGFloat = 12
        /// The selection's inset from the list's sides.
        public static let selectionInset: CGFloat = 6
        /// The time's column, its text right-aligned.
        public static let timeWidth: CGFloat = 44
        /// The short ID's column (7 characters of SF Mono 11).
        public static let shortIDWidth: CGFloat = 58
        /// Below these column widths the graph's short ID, avatar, and time
        /// hide.
        public static let hidesShortIDBelow: CGFloat = 460
        public static let hidesAvatarBelow: CGFloat = 340
        public static let hidesDateBelow: CGFloat = 300
        /// The unpushed arrow's point size.
        public static let unpushedGlyphSize: CGFloat = 10
        /// The most of a title line the ref tags take.
        public static let refsWidthFraction: CGFloat = 0.6
    }

    /// Ref capsules.
    public enum RefCapsule {
        public static let height: CGFloat = 18
        public static let horizontalPadding: CGFloat = 7
        public static let spacing: CGFloat = 4
        /// At most this many capsules, then "+N".
        public static let maximumVisible = 3
        public static let glyphSpacing: CGFloat = 3
    }

    /// Diffs: SF Mono 11.5 for code, in lines 20 high.
    public enum Diff {
        public static let codeFontSize: CGFloat = 11.5
        public static let lineHeight: CGFloat = 20
        /// Code text size limits (⌘= / ⌘− / ⌘0).
        public static let minimumCodeFontSize: CGFloat = 9
        public static let maximumCodeFontSize: CGFloat = 24
    }

    /// The Changes list: an AppKit table with fixed rows, so applying a
    /// status costs only the rows on screen.
    public enum FileList {
        /// The row height: `ceil(lineHeight(.body) × 1.875)`, 30 at the
        /// default text size.
        public static var rowHeight: CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body)) * 1.875)
        }

        /// The status letter's square, and a conflicted file's symbol.
        public static let statusGlyphSize: CGFloat = StatusBadge.size
    }

    /// The header row atop a column (Changes, the stash, History) and atop
    /// the diff: one height, so their hairlines line up.
    public enum PaneHeader {
        public static let height: CGFloat = 40
    }

    /// The Changes column's composer: the commit message card and the
    /// commit button under it.
    public enum Composer {
        /// Space around the composer, beside and below it.
        public static let horizontalPadding: CGFloat = 14
        /// Space inside the card around the summary, the description, and
        /// the co-authors.
        public static let cardPadding: CGFloat = 11
        /// Space above the summary, inside the card's top edge.
        public static let summaryTopPadding: CGFloat = 9
        /// The card's footer row: the AI button, co-authors, and the
        /// options, then the author's avatar.
        public static let footerHeight: CGFloat = 34
        /// Space before the footer's first button: its symbol lines up with
        /// the text above, the button's own room making up the rest.
        public static let footerPadding: CGFloat = 4
        /// The author's avatar, last in the card's footer.
        public static let avatarSize: CGFloat = 20
        /// The hints after the summary (the lightbulb).
        public static let summaryHintSize: CGFloat = 16
        /// A co-author's token in the card.
        public static let coAuthorTokenHeight: CGFloat = 22
        /// The co-authors' field shares the tokens' last row while it has
        /// this much room.
        public static let coAuthorFieldMinimumWidth: CGFloat = 120
        /// The description shows this many lines at least, and grows up to
        /// `descriptionMaximumLines` before it scrolls.
        public static let descriptionMinimumLines = 3
        public static let descriptionMaximumLines = 8
        /// Popovers anchored in the composer (author, AI setup, models).
        public static let popoverWidth: CGFloat = 300
        /// The hook output popover.
        public static let hookOutputWidth: CGFloat = 520
        public static let hookOutputHeight: CGFloat = 260
        /// The Suggestions shown when there are no local changes.
        public static let suggestionsMaximumWidth: CGFloat = 620
    }

    /// The capsule and toasts floating over the detail area.
    public enum Floating {
        /// A toast's and the capsule's height on one line.
        public static let height: CGFloat = 44
        public static let bottomInset: CGFloat = 24
        public static let spacing: CGFloat = 8
        public static let maximumWidth: CGFloat = 560
    }

    /// Sheets.
    public enum Sheet {
        public static let compactWidth: CGFloat = 420
        public static let standardWidth: CGFloat = 520
        public static let terminalWidth: CGFloat = 620
        /// The tallest terminal output gets before it scrolls; shorter
        /// output takes its own height.
        public static let terminalHeight: CGFloat = 260
        /// A list's height in a sheet or a window (the repositories to
        /// clone, at least that in Get Started), and the area Repository
        /// Settings' panes share.
        public static let listHeight: CGFloat = 240
    }

    /// The welcome flow.
    public enum Welcome {
        /// The app icon's size.
        public static let iconSize: CGFloat = 128
        /// The widest a paragraph gets.
        public static let textWidth: CGFloat = 440
        /// The Configure Git form's width.
        public static let formWidth: CGFloat = 480
        /// The sign-in buttons' width.
        public static let buttonWidth: CGFloat = 300
        /// The example commit's avatar.
        public static let avatarSize: CGFloat = 28
    }

    /// About Espalier and its acknowledgements.
    public enum About {
        /// The app icon's size.
        public static let iconSize: CGFloat = 96
        /// The About window's width.
        public static let width: CGFloat = 360
        /// The Acknowledgements sheet.
        public static let acknowledgementsWidth: CGFloat = 800
        public static let acknowledgementsHeight: CGFloat = 540
        /// The list of components beside the license text.
        public static let acknowledgementsListWidth: CGFloat = 220
    }

    /// The Settings window: a sidebar of panes, and the pane under its
    /// header band.
    public enum SettingsWindow {
        /// The window's size; a pane taller than the window scrolls.
        public static let width: CGFloat = 720
        public static let height: CGFloat = 680
        /// The sidebar's width.
        public static let sidebarWidth: CGFloat = 180
        /// The band at the sidebar's top, where the window's buttons sit,
        /// and the pane's header band: both as high as the main window's
        /// toolbar.
        public static let headerHeight: CGFloat = 52
        /// The pane's content and header inset from its sides.
        public static let contentInset: CGFloat = 20
        /// Space above the pane's first section and below its last.
        public static let contentTopInset: CGFloat = 6
        public static let contentBottomInset: CGFloat = 20
        /// Space above and below a section label.
        public static let sectionLabelTop: CGFloat = 18
        public static let sectionLabelBottom: CGFloat = 4
        /// Space above a section without a label.
        public static let untitledSectionTop: CGFloat = 8
        /// A row: at least 46 high with the hairline under it, its content
        /// 9 from its top and bottom, 16 between its text and its control.
        public static let rowHeight: CGFloat = 45
        public static let rowVerticalPadding: CGFloat = 9
        public static let rowSpacing: CGFloat = 16
        /// Between a row's title and its description, and between its
        /// text and a message under it.
        public static let descriptionSpacing: CGFloat = 2
        public static let messageSpacing: CGFloat = 6
        /// Fields and pop-ups in rows.
        public static let controlWidth: CGFloat = 200
        /// A narrow field (a number of seconds).
        public static let narrowControlWidth: CGFloat = 90
        /// An account's avatar.
        public static let avatarSize: CGFloat = 28
    }
}

/// Espalier's timing constants. Animations' durations are `Motion`'s.
public enum Timing {
    /// Spinners appear only after this long.
    public static let spinnerDelay: Duration = .milliseconds(300)
    /// After a switch, the sidebar's sections keep showing the previous
    /// repository at most this long while the selected one loads.
    public static let sidebarHold: Duration = .seconds(1)
    /// The diff's loading overlay appears after this long.
    public static let diffOverlayDelay: Duration = .milliseconds(150)
    /// Hovering a line or stub this long highlights it.
    public static let hoverDwell: Duration = .milliseconds(250)
    /// A toast's time on screen, after the pointer leaves it.
    public static let toast: Duration = .seconds(5)
    /// A toast with Undo stays longer.
    public static let toastWithUndo: Duration = .seconds(15)
    /// VoiceOver hears how many items a filter matches once its text has
    /// been still this long.
    public static let filterResultsAnnouncement: Duration = .seconds(1)
    /// Hovering a menu item this long opens its submenu.
    public static let submenuHover: Duration = .milliseconds(200)
    /// While the pointer heads for an open submenu, the item it passes
    /// over takes the highlight only once it has rested this long.
    public static let submenuSettle: Duration = .milliseconds(300)
    /// Typing selects a menu item by its title's start; a pause this long
    /// starts a new prefix.
    public static let menuTypeSelect: Duration = .seconds(1)
}

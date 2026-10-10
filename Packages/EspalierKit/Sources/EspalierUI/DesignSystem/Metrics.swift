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

    /// Corner radii: rows and cards are generously rounded; controls are
    /// capsules.
    public enum Radius {
        /// Sidebar items and file rows.
        public static let row: CGFloat = 9
        /// The branch picker's rows.
        public static let pickerRow: CGFloat = 11
        /// History's simple mode rows.
        public static let simpleRow: CGFloat = 12
        /// The commit message card.
        public static let card: CGFloat = 14
        /// Banners.
        public static let banner: CGFloat = 14
        /// The empty state's action list.
        public static let actionList: CGFloat = 16
        /// Sheets.
        public static let sheet: CGFloat = 22
        /// The branch picker.
        public static let picker: CGFloat = 22
        /// Checkboxes.
        public static let checkbox: CGFloat = 5
        /// Key caps.
        public static let keyCap: CGFloat = 5
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
        /// The graph list in History and Compare.
        public static let graphList = ColumnWidth(min: 340, ideal: 560, max: 900)
        /// The file list inside a commit's detail.
        public static let commitFileList = ColumnWidth(min: 180, ideal: 220, max: 320)
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

    /// Commit rows: the graph, the ref tags, the summary, the avatar, the
    /// time, and the short ID.
    public enum CommitRow {
        /// The default avatar size of `Avatar`.
        public static let avatarSize: CGFloat = 16
        /// The avatar in History's rows and a commit's details.
        public static let graphAvatarSize: CGFloat = 18
        /// The space between a row's parts.
        public static let spacing: CGFloat = 10
        /// Space after the last part, and the selection's inset from the
        /// row's trailing edge (a selected row is flush with the graph's
        /// edge and rounded on the other side).
        public static let trailingPadding: CGFloat = 12
        public static let selectionInset: CGFloat = 6
        public static let dateWidth: CGFloat = 76
        /// The short ID's column (7 characters of SF Mono 11).
        public static let shortIDWidth: CGFloat = 58
        /// Below these column widths the short ID, avatar, and date hide.
        public static let hidesShortIDBelow: CGFloat = 520
        public static let hidesAvatarBelow: CGFloat = 440
        public static let hidesDateBelow: CGFloat = 380
        /// The unpushed arrow's point size.
        public static let unpushedGlyphSize: CGFloat = 10
    }

    /// Ref capsules.
    public enum RefCapsule {
        public static let height: CGFloat = 18
        public static let cornerRadius: CGFloat = 9
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
        public static let stagingColumnWidth: CGFloat = 16
        public static let minimumLineNumberDigits = 3
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

        /// The status letter's square.
        public static let statusGlyphSize: CGFloat = StatusBadge.size
        /// The conflicts section above the table grows to this height, then
        /// scrolls.
        public static let conflictsMaximumHeight: CGFloat = 240
    }

    /// The Changes column and its composer.
    public enum Composer {
        /// The rounded box around the summary and the description.
        public static let fieldCornerRadius: CGFloat = 8
        /// The author's avatar, leading in the summary row.
        public static let avatarSize: CGFloat = 20
        /// The sparkle and the summary's other trailing symbols.
        public static let sparkleSize: CGFloat = 16
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
        public static let terminalHeight: CGFloat = 260
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
        public static let width: CGFloat = 900
        public static let height: CGFloat = 680
        /// The sidebar's width.
        public static let sidebarWidth: CGFloat = 210
        /// The band at the sidebar's top, where the window's buttons sit,
        /// and the pane's header band: both as high as the main window's
        /// toolbar.
        public static let headerHeight: CGFloat = 52
        /// The pane's content and header inset from its sides.
        public static let contentInset: CGFloat = 22
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
        public static let controlWidth: CGFloat = 210
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
}

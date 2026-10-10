// One row of the history graph: the graph, the ref tags, the summary with
// the unpushed arrow, the author's avatar, the time, and the short ID, laid
// out with manual frames (no Auto Layout in cells). The working copy's row
// shows its changes instead.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import QuartzCore

/// The working copy's changes, as its row shows them.
nonisolated public struct WorkingCopySummary: Sendable, Equatable {
    /// The changed files.
    public var changedFiles: Int
    /// The files with conflicts.
    public var conflictedFiles: Int

    public init(changedFiles: Int = 0, conflictedFiles: Int = 0) {
        self.changedFiles = changedFiles
        self.conflictedFiles = conflictedFiles
    }

    /// Whether there are changes.
    public var isDirty: Bool {
        changedFiles > 0 || conflictedFiles > 0
    }

    /// The row's title.
    public var title: String {
        isDirty ? "Uncommitted Changes" : "No Uncommitted Changes"
    }

    /// The row's detail: the conflicts first, else the changed files.
    public var detail: String? {
        if conflictedFiles > 0 {
            return conflictedFiles == 1 ? "1 conflicted file" : "\(formatCount(conflictedFiles)) conflicted files"
        }
        if changedFiles > 0 {
            return changedFiles == 1 ? "1 changed file" : "\(formatCount(changedFiles)) changed files"
        }
        return nil
    }
}

/// What a row of the history graph shows beside the graph.
nonisolated public struct CommitRowContent: Sendable, Equatable {
    /// A commit, or the working copy.
    public enum Kind: Sendable, Equatable {
        case commit
        case workingCopy(WorkingCopySummary)
    }

    public var kind: Kind
    /// The commit's SHA; nil for the working copy.
    public var sha: String?
    /// The commit's summary ("" shows "Empty commit message").
    public var summary: String
    public var authorName: String
    public var authorEmail: String
    /// The date as the list shows it ("2 hours ago"), and in full for the
    /// tooltip.
    public var date: String
    public var dateTooltip: String
    /// The branches and tags on the commit.
    public var refs: [RefCapsuleContent]
    /// Why the commit shows the unpushed arrow, or nil for no arrow.
    public var unpushedTooltip: String?
    /// The row doesn't match the search.
    public var isDimmed: Bool
    /// The GitHub endpoint avatars load from (nil: GitHub.com's, by email).
    public var avatarEndpoint: String?
    /// A merge commit: its summary is quieter.
    public var isMerge: Bool
    /// The current tip (HEAD's commit): its summary is semibold.
    public var isCurrentTip: Bool

    public init(
        kind: Kind = .commit,
        sha: String? = nil,
        summary: String = "",
        authorName: String = "",
        authorEmail: String = "",
        date: String = "",
        dateTooltip: String = "",
        refs: [RefCapsuleContent] = [],
        unpushedTooltip: String? = nil,
        isDimmed: Bool = false,
        avatarEndpoint: String? = nil,
        isMerge: Bool = false,
        isCurrentTip: Bool = false
    ) {
        self.kind = kind
        self.sha = sha
        self.summary = summary
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.dateTooltip = dateTooltip
        self.refs = refs
        self.unpushedTooltip = unpushedTooltip
        self.isDimmed = isDimmed
        self.avatarEndpoint = avatarEndpoint
        self.isMerge = isMerge
        self.isCurrentTip = isCurrentTip
    }

    /// The working copy's row.
    public static func workingCopy(_ summary: WorkingCopySummary) -> CommitRowContent {
        CommitRowContent(kind: .workingCopy(summary))
    }

    /// The summary as the row shows it.
    public var displaySummary: String {
        summary.isEmpty ? CommitRowContent.emptySummary : summary
    }

    /// The short ID the row ends with.
    public var shortSHA: String {
        sha.map(shortenSHA) ?? ""
    }

    /// The author, as the avatar's tooltip says it.
    public var authorTooltip: String {
        authorEmail.isEmpty ? authorName : "\(authorName) <\(authorEmail)>"
    }

    /// The text for a commit without a message.
    public static let emptySummary = "Empty commit message"

    /// The author as avatars see them.
    var avatarUser: AvatarUser {
        AvatarUser(email: authorEmail, avatarURL: nil, name: authorName, endpoint: avatarEndpoint)
    }
}

/// Formats a count with grouping separators ("1,204").
nonisolated func formatCount(_ count: Int) -> String {
    count.formatted(.number.locale(Locale(identifier: "en_US")))
}

/// One row of the history graph: the graph, then the commit's refs,
/// summary, avatar, time, and short ID.
final class CommitRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitRow")

    let graphView = GraphCellView(frame: .zero)
    private let refsView = RefCapsulesView(frame: .zero)
    private let summaryLabel = CommitRowCellView.label(font: AppKitTypography.row, color: Palette.text)
    private let detailLabel = CommitRowCellView.label(font: AppKitTypography.secondary, color: Palette.text3)
    private let warningView = NSImageView()
    private let unpushedView = NSImageView()
    private let avatarView = RowAvatarView(frame: .zero)
    private let dateLabel = CommitRowCellView.label(font: AppKitTypography.secondary, color: Palette.text3, alignment: .right)
    private let shortIDLabel = CommitRowCellView.label(font: AppKitTypography.code(size: 11), color: Palette.text3, alignment: .right)

    /// What the row shows.
    private(set) var content = CommitRowContent()
    private var summaryWidth: CGFloat = 0
    private var isDimmed = false
    /// The date column's width, the same in every row.
    private var dateWidth = Metrics.CommitRow.dateWidth

    /// The heights of one line of the row's fonts, measured once.
    private static let rowLabelHeight = ceil(CommitRowCellView.label(font: AppKitTypography.row, color: .labelColor, sample: true).intrinsicContentSize.height)
    private static let secondaryLabelHeight = ceil(CommitRowCellView.label(font: AppKitTypography.secondary, color: .labelColor, sample: true).intrinsicContentSize.height)
    private static let shortIDHeight = ceil(CommitRowCellView.label(font: AppKitTypography.code(size: 11), color: .labelColor, sample: true).intrinsicContentSize.height)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(graphView)
        addSubview(refsView)
        addSubview(summaryLabel)
        addSubview(detailLabel)
        for imageView in [warningView, unpushedView] {
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityElement(false)
            addSubview(imageView)
        }
        let unpushedConfiguration = NSImage.SymbolConfiguration(pointSize: Metrics.CommitRow.unpushedGlyphSize, weight: .semibold)
        unpushedView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(unpushedConfiguration)
        unpushedView.contentTintColor = Palette.accent
        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.preferringMulticolor())
        avatarView.fadesIn = true
        addSubview(avatarView)
        addSubview(dateLabel)
        addSubview(shortIDLabel)
        textField = summaryLabel
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    /// The width a label needs to show its text untruncated: its cell's
    /// size, which includes the cell's padding.
    static func fittingWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
    }

    private static func label(font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, sample: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: sample ? "Xg" : "")
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        return label
    }

    // MARK: Configuring

    /// Shows `content` with the graph's `drawing`, styled by `style`.
    func configure(_ content: CommitRowContent, drawing: GraphRowDrawing, emphasis: GraphEmphasis, style: GraphRowStyle) {
        if graphView.geometry != style.geometry || dateWidth != style.dateWidth {
            graphView.geometry = style.geometry
            dateWidth = style.dateWidth
            needsLayout = true
        }
        graphView.colors = style.colors
        graphView.drawing = drawing
        var emphasis = emphasis
        emphasis.isSelected = isSelectedRow
        graphView.emphasis = emphasis
        refsView.palette = style.palette

        let contentChanged = content != self.content
        self.content = content
        if contentChanged {
            apply(content, avatars: style.avatars, monograms: style.monograms, scale: style.scale)
            needsLayout = true
        }
    }

    private func apply(_ content: CommitRowContent, avatars: (any AvatarLoading)?, monograms: MonogramCache, scale: CGFloat) {
        let alpha: CGFloat = content.isDimmed ? Metrics.Graph.searchDimming : 1
        switch content.kind {
        case .workingCopy(let summary):
            summaryLabel.stringValue = summary.title
            summaryLabel.font = AppKitTypography.row
            summaryLabel.textColor = summary.isDirty ? Palette.text : Palette.text3
            summaryLabel.toolTip = nil
            detailLabel.stringValue = summary.detail ?? ""
            detailLabel.isHidden = summary.detail == nil
            warningView.isHidden = summary.conflictedFiles == 0
            refsView.refs = []
            unpushedView.isHidden = true
            avatarView.isHidden = true
            avatarView.toolTip = nil
            dateLabel.isHidden = true
            shortIDLabel.isHidden = true
            avatarView.show(nil, pointSize: Metrics.CommitRow.graphAvatarSize, avatars: nil, monograms: monograms, scale: scale)
        case .commit:
            summaryLabel.stringValue = content.displaySummary
            summaryLabel.font = content.isCurrentTip ? Self.currentTipFont : AppKitTypography.row
            summaryLabel.textColor = content.summary.isEmpty || content.isMerge ? Palette.text3 : Palette.text
            summaryLabel.toolTip = content.displaySummary
            detailLabel.isHidden = true
            warningView.isHidden = true
            refsView.refs = content.refs
            unpushedView.isHidden = content.unpushedTooltip == nil
            unpushedView.toolTip = content.unpushedTooltip
            avatarView.toolTip = content.authorTooltip
            dateLabel.stringValue = content.date
            dateLabel.toolTip = content.dateTooltip
            shortIDLabel.stringValue = content.shortSHA
            shortIDLabel.toolTip = content.sha
            avatarView.isHidden = false
            dateLabel.isHidden = false
            shortIDLabel.isHidden = false
            avatarView.show(content.avatarUser, pointSize: Metrics.CommitRow.graphAvatarSize, avatars: avatars, monograms: monograms, scale: scale)
        }
        summaryWidth = Self.fittingWidth(summaryLabel)
        if content.isDimmed != isDimmed {
            isDimmed = content.isDimmed
            for view in [summaryLabel, detailLabel, refsView, unpushedView, avatarView, dateLabel, shortIDLabel, warningView] as [NSView] {
                view.alphaValue = alpha
            }
        }
    }

    /// The current tip's summary: the row's font, semibold.
    private static var currentTipFont: NSFont {
        .systemFont(ofSize: AppKitTypography.row.pointSize, weight: .semibold)
    }

    /// Updates the date (the once-a-minute refresh).
    func updateDate(_ date: String, tooltip: String) {
        guard date != content.date || tooltip != content.dateTooltip else {
            return
        }
        content.date = date
        content.dateTooltip = tooltip
        dateLabel.stringValue = date
        dateLabel.toolTip = tooltip
    }

    // MARK: Selection

    /// Whether the row is selected (`GraphRowView` says): rings fill with
    /// the selection's tint. Text keeps its colors on the soft selection.
    var isSelectedRow = false {
        didSet {
            guard isSelectedRow != oldValue else {
                return
            }
            var emphasis = graphView.emphasis
            emphasis.isSelected = isSelectedRow
            graphView.emphasis = emphasis
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let geometry = graphView.geometry
        graphView.frame = CGRect(x: 0, y: 0, width: geometry.columnWidth, height: height)

        let width = bounds.width
        let spacing = Metrics.CommitRow.spacing
        let showsDate = width >= Metrics.CommitRow.hidesDateBelow
        let showsAvatar = width >= Metrics.CommitRow.hidesAvatarBelow
        let showsShortID = width >= Metrics.CommitRow.hidesShortIDBelow
        var leading = geometry.columnWidth + spacing
        var trailing = width - Metrics.CommitRow.selectionInset - Metrics.CommitRow.trailingPadding

        func centered(_ size: CGSize, x: CGFloat) -> CGRect {
            CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        }

        if case .workingCopy = content.kind {
            if !warningView.isHidden {
                warningView.frame = centered(CGSize(width: 14, height: 14), x: leading)
                leading += 14 + Metrics.grid
            }
            summaryLabel.frame = centered(CGSize(width: min(summaryWidth, max(trailing - leading, 0)), height: Self.rowLabelHeight), x: leading)
            leading = summaryLabel.frame.maxX + Metrics.insetSmall
            detailLabel.frame = centered(CGSize(width: max(trailing - leading, 0), height: Self.secondaryLabelHeight), x: leading)
            refsView.frame = .zero
            return
        }

        // Right to left: the short ID, the time, the avatar.
        shortIDLabel.isHidden = !showsShortID
        if showsShortID {
            let size = CGSize(width: Metrics.CommitRow.shortIDWidth, height: Self.shortIDHeight)
            shortIDLabel.frame = centered(size, x: trailing - size.width)
            trailing = shortIDLabel.frame.minX - spacing
        }
        dateLabel.isHidden = !showsDate
        if showsDate {
            let size = CGSize(width: dateWidth, height: Self.secondaryLabelHeight)
            dateLabel.frame = centered(size, x: trailing - size.width)
            trailing = dateLabel.frame.minX - spacing
        }
        avatarView.isHidden = !showsAvatar
        if showsAvatar {
            let size = Metrics.CommitRow.graphAvatarSize
            avatarView.frame = centered(CGSize(width: size, height: size), x: trailing - size)
            trailing = avatarView.frame.minX - spacing
        }

        // Left to right: the refs, the summary, the unpushed arrow.
        let available = max(trailing - leading, 0)
        let refsWidth = refsView.layoutCapsules(maximumWidth: available * 0.6)
        refsView.frame = CGRect(x: leading, y: ((height - Metrics.RefCapsule.height) / 2).rounded(), width: refsWidth, height: Metrics.RefCapsule.height)
        if refsWidth > 0 {
            leading += refsWidth + Metrics.RefCapsule.horizontalPadding
        }
        let arrowWidth: CGFloat = unpushedView.isHidden ? 0 : Metrics.CommitRow.unpushedGlyphSize + Metrics.grid
        let summarySpace = max(trailing - leading - arrowWidth, 0)
        summaryLabel.frame = centered(CGSize(width: min(summaryWidth, summarySpace), height: Self.rowLabelHeight), x: leading)
        if !unpushedView.isHidden {
            let size = CGSize(width: Metrics.CommitRow.unpushedGlyphSize + 2, height: Metrics.CommitRow.unpushedGlyphSize + 2)
            unpushedView.frame = centered(size, x: summaryLabel.frame.maxX + Metrics.grid / 2)
        }
    }

    // MARK: Accessibility

    /// The facts about a row, computed when VoiceOver asks.
    var accessibilityValueProvider: ((_ row: Int) -> String?)?
    /// The row's actions (Check Out Commit, Copy SHA, …), made when
    /// VoiceOver asks.
    var accessibilityActionsProvider: ((_ row: Int) -> [NSAccessibilityCustomAction])?

    override func accessibilityValue() -> Any? {
        graphView.drawing.flatMap { accessibilityValueProvider?($0.index) }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        graphView.drawing.flatMap { accessibilityActionsProvider?($0.index) }
    }

    /// VoiceOver's Show Menu: the menu a right-click on the row shows.
    override func accessibilityPerformShowMenu() -> Bool {
        KeyboardContextMenu.showMenu(of: self)
    }

    /// The row's description: "<summary>. <author>, <relative date>."; the
    /// facts about it are the value.
    override func accessibilityLabel() -> String? {
        switch content.kind {
        case .workingCopy(let summary):
            summary.isDirty ? "Uncommitted changes, \(summary.detail ?? "")." : "No uncommitted changes."
        case .commit:
            "\(content.displaySummary). \(content.authorName), \(content.date)."
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.cancel()
        graphView.emphasis = GraphEmphasis()
        isSelectedRow = false
    }
}

/// What every row of one graph table shares: its geometry, colors, and
/// avatars.
struct GraphRowStyle {
    var geometry: GraphGeometry
    var colors: GraphColors
    var palette: TrackPalette.Resolved
    /// Where avatars come from (monograms when nil).
    var avatars: (any AvatarLoading)?
    var monograms: MonogramCache
    /// The backing scale avatars are drawn at.
    var scale: CGFloat
    /// The date column's width: wide enough for the dates the formatting
    /// makes (76 points fit short relative dates).
    var dateWidth = Metrics.CommitRow.dateWidth

    /// The date column's width for `formatting`: the widest of a few long
    /// dates in it.
    static func dateWidth(for formatting: DateTimeFormatting) -> CGFloat {
        let samples: [String]
        if formatting.preferAbsoluteDates {
            // A long month, day, and hour.
            let sample = Date(timeIntervalSince1970: 1_758_027_300)
            samples = [RelativeTime.formatDate(sample, formatting: formatting, timeZone: TimeZone(identifier: "UTC")!)]
        } else {
            samples = ["55 minutes ago", "23 hours ago", "29 days ago", "11 months ago", "18 years ago"]
        }
        let font = AppKitTypography.secondary
        let widest = samples.map { ceil(NSAttributedString(string: $0, attributes: [.font: font]).size().width) + 4 }.max() ?? 0
        return max(Metrics.CommitRow.dateWidth, widest)
    }
}

extension CommitRowCellView {
    /// A trailing column of a commit's row.
    enum TrailingColumn: Hashable {
        case avatar, date, shortID
    }

    /// The trailing columns the last layout shows: narrow rows hide the
    /// short ID, then the avatar, then the date.
    var shownTrailingColumns: Set<TrailingColumn> {
        var shown: Set<TrailingColumn> = []
        if !avatarView.isHidden {
            shown.insert(.avatar)
        }
        if !dateLabel.isHidden {
            shown.insert(.date)
        }
        if !shortIDLabel.isHidden {
            shown.insert(.shortID)
        }
        return shown
    }
}

// One row of the history graph: the graph, the author's avatar, the ref tags,
// the title with the unpushed arrow, the time, and the short ID, laid out with
// manual frames (no Auto Layout in cells). The simple list's rows use the same
// parts (`CommitRowParts`), on two lines and beside a rail instead of lanes.
// The working copy's row shows its changes instead.

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

    /// The row's detail: the conflicts first, else the changed files, the
    /// count in `numberFormat`.
    public func detail(_ numberFormat: NumberFormat) -> String? {
        if conflictedFiles > 0 {
            return conflictedFiles == 1 ? "1 conflicted file" : "\(formatCount(conflictedFiles, numberFormat)) conflicted files"
        }
        if changedFiles > 0 {
            return changedFiles == 1 ? "1 changed file" : "\(formatCount(changedFiles, numberFormat)) changed files"
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
    /// The date in words (VoiceOver reads it), as the time column shows it
    /// ("12m", "Oct 5"), and in full for the tooltip.
    public var date: String
    public var shortDate: String
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
    /// The format the row's counts show in: the working copy's files, the
    /// refs past the capsules shown, and the graph's stub counts.
    public var numberFormat: NumberFormat

    public init(
        kind: Kind = .commit,
        sha: String? = nil,
        summary: String = "",
        authorName: String = "",
        authorEmail: String = "",
        date: String = "",
        shortDate: String = "",
        dateTooltip: String = "",
        refs: [RefCapsuleContent] = [],
        unpushedTooltip: String? = nil,
        isDimmed: Bool = false,
        avatarEndpoint: String? = nil,
        isMerge: Bool = false,
        isCurrentTip: Bool = false,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.kind = kind
        self.sha = sha
        self.summary = summary
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.shortDate = shortDate
        self.dateTooltip = dateTooltip
        self.refs = refs
        self.unpushedTooltip = unpushedTooltip
        self.isDimmed = isDimmed
        self.avatarEndpoint = avatarEndpoint
        self.isMerge = isMerge
        self.isCurrentTip = isCurrentTip
        self.numberFormat = numberFormat
    }

    /// The working copy's row, its counts in `numberFormat`.
    public static func workingCopy(_ summary: WorkingCopySummary, numberFormat: NumberFormat) -> CommitRowContent {
        CommitRowContent(kind: .workingCopy(summary), numberFormat: numberFormat)
    }

    /// The summary as the row shows it.
    public var displaySummary: String {
        summary.isEmpty ? CommitRowContent.emptySummary : summary
    }

    /// Whether this is `old`'s row changed in place: the same commit with
    /// other refs, unpushed arrow, or weight (HEAD moved), or the working
    /// copy with other changes. Not a row reused for another commit, nor a
    /// search dimming it.
    func changesInPlace(from old: CommitRowContent) -> Bool {
        switch (old.kind, kind) {
        case (.workingCopy(let oldSummary), .workingCopy(let summary)):
            return oldSummary != summary
        case (.commit, .commit):
            guard let sha, sha == old.sha else {
                return false
            }
            return refs != old.refs || unpushedTooltip != old.unpushedTooltip || isCurrentTip != old.isCurrentTip
        default:
            return false
        }
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

    /// The tooltip of an unpushed commit's arrow.
    public static let notPushedTooltip = "This commit has not been pushed to the remote repository"

    /// The author as avatars see them.
    var avatarUser: AvatarUser {
        AvatarUser(email: authorEmail, avatarURL: nil, name: authorName, endpoint: avatarEndpoint)
    }
}

/// The parts History's commit rows share, so the graph's and the simple
/// list's look alike: their labels, the unpushed arrow, and the title
/// line's layout.
@MainActor
enum CommitRowParts {
    /// A one-line label.
    static func label(font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, sample: Bool = false) -> NSTextField {
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

    /// The width a label needs to show its text untruncated: its cell's
    /// size, which includes the cell's padding.
    static func fittingWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
    }

    /// The height of one line of `font` in a label, measured once per
    /// font.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        if let height = lineHeights[font] {
            return height
        }
        let height = ceil(label(font: font, color: .labelColor, sample: true).intrinsicContentSize.height)
        lineHeights[font] = height
        return height
    }

    private static var lineHeights: [NSFont: CGFloat] = [:]

    /// A title's font: the row's, semibold for HEAD's commit.
    static func titleFont(isCurrentTip: Bool) -> NSFont {
        isCurrentTip ? AppKitTypography.row(weight: .semibold) : AppKitTypography.row
    }

    /// The time label: secondary text, right-aligned in its column.
    static func timeLabel() -> NSTextField {
        label(font: AppKitTypography.secondary, color: Palette.text3, alignment: .right)
    }

    /// The unpushed arrow: an accent arrow after the title.
    static func unpushedArrow() -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.CommitRow.unpushedGlyphSize, weight: .semibold))
        view.contentTintColor = Palette.accent
        view.setAccessibilityElement(false)
        return view
    }

    /// Lays a title line out from `leading` to `trailing`, centered on
    /// `midY`: the ref tags (at most `refsWidthFraction` of the line), the
    /// title, and the unpushed arrow right after it, when it shows.
    static func layoutTitleLine(
        refs: RefCapsulesView,
        title: NSTextField,
        titleWidth: CGFloat,
        titleHeight: CGFloat,
        unpushed: NSImageView,
        leading: CGFloat,
        trailing: CGFloat,
        midY: CGFloat
    ) {
        var leading = leading
        let available = max(trailing - leading, 0)
        let refsWidth = refs.layoutCapsules(maximumWidth: available * Metrics.CommitRow.refsWidthFraction)
        refs.frame = CGRect(x: leading, y: (midY - Metrics.RefCapsule.height / 2).rounded(), width: refsWidth, height: Metrics.RefCapsule.height)
        if refsWidth > 0 {
            leading += refsWidth + Metrics.insetSmall
        }
        let glyph = Metrics.CommitRow.unpushedGlyphSize
        let arrowWidth: CGFloat = unpushed.isHidden ? 0 : glyph + Metrics.grid
        let titleSpace = max(trailing - leading - arrowWidth, 0)
        title.frame = CGRect(x: leading, y: (midY - titleHeight / 2).rounded(), width: min(titleWidth, titleSpace), height: titleHeight)
        if !unpushed.isHidden {
            // The symbol's frame is a little larger than its point size.
            let side = glyph + Metrics.grid / 2
            unpushed.frame = CGRect(x: title.frame.maxX + Metrics.grid / 2, y: (midY - side / 2).rounded(), width: side, height: side)
        }
    }
}

/// One row of the history graph: the graph, then the commit's avatar,
/// refs, summary, time, and short ID.
final class CommitRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitRow")

    let graphView = GraphCellView(frame: .zero)
    private let refsView = RefCapsulesView(frame: .zero)
    private let summaryLabel = CommitRowParts.label(font: AppKitTypography.row, color: Palette.text)
    private let detailLabel = CommitRowParts.label(font: AppKitTypography.secondary, color: Palette.text3)
    private let warningView = NSImageView()
    private let unpushedView = CommitRowParts.unpushedArrow()
    private let avatarView = RowAvatarView(frame: .zero)
    private let dateLabel = CommitRowParts.timeLabel()
    private let shortIDLabel = CommitRowParts.label(font: AppKitTypography.code(size: 11), color: Palette.text3, alignment: .right)

    /// What the row shows.
    private(set) var content = CommitRowContent()
    private var summaryWidth: CGFloat = 0
    private var isDimmed = false
    /// The look the row's fonts and colors are in.
    private var styledLook = Look.current

    /// The heights of one line of the row's fonts in the current text
    /// fonts.
    private static var rowLabelHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.row) }
    private static var secondaryLabelHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.secondary) }
    private static var shortIDHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.code(size: 11)) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(graphView)
        addSubview(refsView)
        addSubview(summaryLabel)
        addSubview(detailLabel)
        warningView.imageScaling = .scaleProportionallyDown
        warningView.setAccessibilityElement(false)
        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.preferringMulticolor())
        addSubview(warningView)
        addSubview(unpushedView)
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

    // MARK: Configuring

    /// Shows `content` with the graph's `drawing`, styled by `style`. When
    /// `animatesChange` and the row's commit (or the working copy) shows
    /// something else now, the row crossfades to it over 0.15 s.
    func configure(_ content: CommitRowContent, drawing: GraphRowDrawing, emphasis: GraphEmphasis, style: GraphRowStyle, animatesChange: Bool = false) {
        if animatesChange, content.changesInPlace(from: self.content), Motion.animates(self) {
            Motion.crossfade(layer, duration: Motion.leave)
        }
        if graphView.geometry != style.geometry {
            graphView.geometry = style.geometry
            needsLayout = true
        }
        graphView.colors = style.colors
        graphView.numberFormat = content.numberFormat
        graphView.drawing = drawing
        var emphasis = emphasis
        emphasis.isSelected = isSelectedRow
        graphView.emphasis = emphasis
        refsView.palette = style.palette

        var contentChanged = content != self.content
        if styledLook != Look.current {
            restyle()
            contentChanged = true
        }
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
            summaryLabel.setTooltip(nil)
            let detail = summary.detail(content.numberFormat)
            detailLabel.stringValue = detail ?? ""
            detailLabel.isHidden = detail == nil
            warningView.isHidden = summary.conflictedFiles == 0
            refsView.refs = []
            unpushedView.isHidden = true
            avatarView.isHidden = true
            avatarView.setTooltip(nil)
            dateLabel.isHidden = true
            shortIDLabel.isHidden = true
            avatarView.show(nil, pointSize: Metrics.CommitRow.rowAvatarSize, avatars: nil, monograms: monograms, scale: scale)
        case .commit:
            summaryLabel.stringValue = content.displaySummary
            summaryLabel.font = CommitRowParts.titleFont(isCurrentTip: content.isCurrentTip)
            summaryLabel.textColor = content.summary.isEmpty || content.isMerge ? Palette.text3 : Palette.text
            summaryLabel.setTooltip(content.displaySummary)
            detailLabel.isHidden = true
            warningView.isHidden = true
            refsView.numberFormat = content.numberFormat
            refsView.refs = content.refs
            unpushedView.isHidden = content.unpushedTooltip == nil
            unpushedView.setTooltip(content.unpushedTooltip)
            avatarView.setTooltip(content.authorTooltip)
            dateLabel.stringValue = content.shortDate
            dateLabel.setTooltip(content.dateTooltip)
            shortIDLabel.stringValue = content.shortSHA
            shortIDLabel.setTooltip(content.sha)
            avatarView.isHidden = false
            dateLabel.isHidden = false
            shortIDLabel.isHidden = false
            avatarView.show(content.avatarUser, pointSize: Metrics.CommitRow.rowAvatarSize, avatars: avatars, monograms: monograms, scale: scale)
        }
        summaryWidth = CommitRowParts.fittingWidth(summaryLabel)
        if content.isDimmed != isDimmed {
            isDimmed = content.isDimmed
            for view in [summaryLabel, detailLabel, refsView, unpushedView, avatarView, dateLabel, shortIDLabel, warningView] as [NSView] {
                view.alphaValue = alpha
            }
        }
    }

    /// Updates the date (the once-a-minute refresh).
    func updateDate(_ date: String, short: String, tooltip: String) {
        guard date != content.date || short != content.shortDate || tooltip != content.dateTooltip else {
            return
        }
        content.date = date
        content.shortDate = short
        content.dateTooltip = tooltip
        dateLabel.stringValue = short
        dateLabel.setTooltip(tooltip)
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

    /// Takes the current look's fonts and colors.
    private func restyle() {
        styledLook = Look.current
        detailLabel.font = AppKitTypography.secondary
        detailLabel.textColor = Palette.text3
        dateLabel.font = AppKitTypography.secondary
        dateLabel.textColor = Palette.text3
        shortIDLabel.font = AppKitTypography.code(size: 11)
        shortIDLabel.textColor = Palette.text3
        unpushedView.contentTintColor = Palette.accent
        needsLayout = true
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
                // The symbol at the row's text size.
                let side: CGFloat = 14
                warningView.frame = centered(CGSize(width: side, height: side), x: leading)
                leading += side + Metrics.grid
            }
            summaryLabel.frame = centered(CGSize(width: min(summaryWidth, max(trailing - leading, 0)), height: Self.rowLabelHeight), x: leading)
            leading = summaryLabel.frame.maxX + Metrics.insetSmall
            detailLabel.frame = centered(CGSize(width: max(trailing - leading, 0), height: Self.secondaryLabelHeight), x: leading)
            refsView.frame = .zero
            return
        }

        // Right to left: the short ID, then the time.
        shortIDLabel.isHidden = !showsShortID
        if showsShortID {
            let size = CGSize(width: Metrics.CommitRow.shortIDWidth, height: Self.shortIDHeight)
            shortIDLabel.frame = centered(size, x: trailing - size.width)
            trailing = shortIDLabel.frame.minX - spacing
        }
        dateLabel.isHidden = !showsDate
        if showsDate {
            let size = CGSize(width: Metrics.CommitRow.timeWidth, height: Self.secondaryLabelHeight)
            dateLabel.frame = centered(size, x: trailing - size.width)
            trailing = dateLabel.frame.minX - spacing
        }

        // Left to right: the avatar, then the title line.
        avatarView.isHidden = !showsAvatar
        if showsAvatar {
            let size = Metrics.CommitRow.rowAvatarSize
            avatarView.frame = centered(CGSize(width: size, height: size), x: leading)
            leading = avatarView.frame.maxX + spacing
        }
        CommitRowParts.layoutTitleLine(
            refs: refsView,
            title: summaryLabel,
            titleWidth: summaryWidth,
            titleHeight: Self.rowLabelHeight,
            unpushed: unpushedView,
            leading: leading,
            trailing: trailing,
            midY: height / 2
        )
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
            summary.isDirty ? "Uncommitted changes, \(summary.detail(content.numberFormat) ?? "")." : "No uncommitted changes."
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
}

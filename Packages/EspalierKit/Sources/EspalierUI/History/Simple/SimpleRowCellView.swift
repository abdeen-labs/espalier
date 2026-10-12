// A row of History's simple list: the rail, then the parts of every History
// row (`CommitRowParts`): the avatar (or a merge's symbol in a soft circle),
// the commit's tags before its title and the unpushed arrow after it, and the
// time in its column ("12m", "Oct 5"); under the title, a meta line ("Maya
// Chen · 4 files"). A merge reads "Merged #209" with its branch in text3, and
// ends with a chevron that expands it; the commits it brought in are indented
// under it, on its stub. Manual frames, no Auto Layout, as in the graph's
// rows.

import AppKit
import EspalierCore
import GitHubKit

/// What a row of the simple list shows.
nonisolated struct SimpleRowContent: Sendable, Equatable {
    /// What kind of row it is.
    enum Kind: Sendable, Equatable {
        /// A commit on the branch's line.
        case commit
        /// A merge on the branch's line: what it merged (nil when its
        /// message doesn't say), and whether it shows its commits.
        case merge(title: MergeTitle?, isExpanded: Bool)
        /// A commit a merge brought in, indented under it.
        case mergedCommit
    }

    /// "Merged #209" and the branch after it.
    struct MergeTitle: Sendable, Equatable {
        var title: String
        var branch: String?
    }

    var kind = Kind.commit
    var sha = ""
    /// The commit's summary ("" shows "Empty commit message").
    var summary = ""
    var authorName = ""
    var authorEmail = ""
    /// The date in words (VoiceOver reads it), as the time column shows it
    /// ("12m", "Oct 5"), and in full for the tooltip.
    var date = ""
    var shortDate = ""
    var dateTooltip = ""
    var changedFileCount = 0
    var tags: [String] = []
    var isUnpushed = false
    /// HEAD's commit: its title is semibold, as in the graph.
    var isCurrentTip = false
    /// The row doesn't match the search.
    var isDimmed = false
    /// The GitHub endpoint avatars load from.
    var avatarEndpoint: String?

    /// The summary as the row shows it.
    var displaySummary: String {
        summary.isEmpty ? CommitRowContent.emptySummary : summary
    }

    /// "4 files", or "1 file".
    var filesText: String {
        changedFileCount == 1 ? "1 file" : "\(formatCount(changedFileCount)) files"
    }

    /// "Maya Chen · 4 files".
    var metaText: String {
        [authorName, filesText].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// The merge row's title: "Merged #209 jonas/widget-refresh"; nil for
    /// other rows, and merges whose message names nothing.
    var mergeTitle: MergeTitle? {
        if case .merge(let title, _) = kind {
            return title
        }
        return nil
    }

    var isMerge: Bool {
        if case .merge = kind {
            return true
        }
        return false
    }

    var isExpanded: Bool {
        if case .merge(_, let isExpanded) = kind {
            return isExpanded
        }
        return false
    }

    var isIndented: Bool {
        kind == .mergedCommit
    }

    var avatarUser: AvatarUser {
        AvatarUser(email: authorEmail, avatarURL: nil, name: authorName, endpoint: avatarEndpoint)
    }

    /// What VoiceOver reads: the title, who and when, the files, and
    /// whether it's pushed.
    var accessibilityLabel: String {
        let title = mergeTitle.map { [$0.title, $0.branch].compactMap(\.self).joined(separator: " ") } ?? displaySummary
        var parts = ["\(title).", "\(authorName), \(date).", "\(filesText)."]
        if isUnpushed {
            parts.append("Not pushed.")
        }
        if !tags.isEmpty {
            parts.append(tags.count == 1 ? "Tag \(tags[0])." : "Tags \(tags.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    /// The title of a merge: "Merged #209" with the branch, "Merged
    /// fix/x", or nil when the message names neither.
    static func mergeTitle(_ merge: SimpleHistoryMerge) -> MergeTitle? {
        if let number = merge.pullRequestNumber {
            return MergeTitle(title: "Merged #\(number)", branch: merge.branchName)
        }
        if let branch = merge.branchName {
            return MergeTitle(title: "Merged", branch: branch)
        }
        return nil
    }
}

/// A row of the simple list.
final class SimpleRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SimpleRow")

    private let railView = SimpleRailView(frame: .zero)
    private let avatarView = RowAvatarView(frame: .zero)
    private let mergeSymbol = NSImageView()
    private let summaryLabel = CommitRowParts.label(font: AppKitTypography.row, color: Palette.text)
    private let refsView = RefCapsulesView(frame: .zero)
    private let unpushedArrow = CommitRowParts.unpushedArrow()
    private let metaLabel = CommitRowParts.label(font: AppKitTypography.simpleMeta, color: Palette.text3)
    private let timeLabel = CommitRowParts.timeLabel()
    private let disclosure = NSImageView()
    /// The look the row's fonts and colors are in.
    private var styledLook = Look.current

    private(set) var content = SimpleRowContent()
    /// Whether the row sits under an expanded merge or is one: it keeps
    /// the chevron's column, so its time lines up with the merge's.
    private(set) var keepsDisclosureColumn = false
    private var summaryWidth: CGFloat = 0
    private var metaWidth: CGFloat = 0

    private static var summaryHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.row) }
    private static var metaHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.simpleMeta) }
    private static var timeHeight: CGFloat { CommitRowParts.lineHeight(AppKitTypography.secondary) }

    /// The views that dim when the row doesn't match the search (the
    /// rail dims its node).
    private var dimmableViews: [NSView] {
        [avatarView, mergeSymbol, summaryLabel, refsView, unpushedArrow, metaLabel, timeLabel, disclosure]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        mergeSymbol.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.SimpleList.mergeSymbolSize, weight: .regular))
        mergeSymbol.contentTintColor = Palette.text2
        mergeSymbol.imageAlignment = .alignCenter
        mergeSymbol.wantsLayer = true
        unpushedArrow.setTooltip(CommitRowContent.notPushedTooltip)
        disclosure.contentTintColor = Palette.text3
        disclosure.imageAlignment = .alignCenter
        for view in [railView, avatarView, mergeSymbol, summaryLabel, refsView, unpushedArrow, metaLabel, timeLabel, disclosure] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
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

    /// Shows `content` with `rail`, with avatars from `avatars` (monograms
    /// when nil); `keepsDisclosureColumn` for a merge's commits.
    func configure(
        _ content: SimpleRowContent,
        rail: SimpleRail,
        keepsDisclosureColumn: Bool,
        avatars: (any AvatarLoading)?,
        monograms: MonogramCache,
        scale: CGFloat
    ) {
        railView.rail = rail
        if keepsDisclosureColumn != self.keepsDisclosureColumn {
            self.keepsDisclosureColumn = keepsDisclosureColumn
            needsLayout = true
        }
        if styledLook != Look.current {
            restyle()
        } else if content == self.content {
            return
        }
        let previous = self.content
        self.content = content
        let titleFont = CommitRowParts.titleFont(isCurrentTip: content.isCurrentTip)
        if let title = content.mergeTitle {
            let text = NSMutableAttributedString(string: title.title, attributes: [
                .font: titleFont,
                .foregroundColor: Palette.text,
            ])
            if let branch = title.branch {
                text.append(NSAttributedString(string: " \(branch)", attributes: [
                    .font: titleFont,
                    .foregroundColor: Palette.text3,
                ]))
            }
            summaryLabel.attributedStringValue = text
        } else {
            summaryLabel.font = titleFont
            summaryLabel.textColor = content.summary.isEmpty ? Palette.text3 : Palette.text
            summaryLabel.stringValue = content.displaySummary
        }
        summaryLabel.setTooltip(content.displaySummary)
        summaryWidth = CommitRowParts.fittingWidth(summaryLabel)
        refsView.refs = content.tags.map { RefCapsuleContent(name: $0, kind: .tag) }
        unpushedArrow.isHidden = !content.isUnpushed
        metaLabel.stringValue = content.metaText
        metaLabel.setTooltip(content.authorEmail.isEmpty ? content.authorName : "\(content.authorName) <\(content.authorEmail)>")
        metaWidth = CommitRowParts.fittingWidth(metaLabel)
        timeLabel.stringValue = content.shortDate
        timeLabel.setTooltip(content.dateTooltip)
        let isMerge = content.isMerge
        mergeSymbol.isHidden = !isMerge
        avatarView.isHidden = isMerge
        disclosure.isHidden = !isMerge
        if isMerge {
            disclosure.image = NSImage(
                systemSymbolName: content.isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: Metrics.SimpleList.disclosureSize, weight: .semibold))
            if previous.isMerge, previous.sha == content.sha, previous.isExpanded != content.isExpanded {
                turnDisclosure(expanding: content.isExpanded)
            }
            avatarView.show(nil, pointSize: Metrics.CommitRow.rowAvatarSize, avatars: nil, monograms: monograms, scale: scale)
        } else {
            avatarView.show(content.avatarUser, pointSize: Metrics.CommitRow.rowAvatarSize, avatars: avatars, monograms: monograms, scale: scale)
        }
        let alpha: CGFloat = content.isDimmed ? Metrics.Graph.searchDimming : 1
        for view in dimmableViews {
            view.alphaValue = alpha
        }
        needsLayout = true
    }

    /// Turns the chevron the quarter turn to its new symbol over 0.15 s (a
    /// disclosure's motion): the new symbol shows at once, starting from the
    /// old one's angle. Clockwise to expand.
    private func turnDisclosure(expanding: Bool) {
        guard Motion.animates(self), let layer = disclosure.layer else {
            return
        }
        // About the chevron's center (AppKit's layers turn about their
        // origin); in this flipped row a positive angle is clockwise.
        let center = CGPoint(
            x: layer.bounds.midX - layer.anchorPoint.x * layer.bounds.width,
            y: layer.bounds.midY - layer.anchorPoint.y * layer.bounds.height
        )
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DRotate(from, expanding ? -.pi / 2 : .pi / 2, 0, 0, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = NSValue(caTransform3D: from)
        turn.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        turn.duration = Motion.leave
        turn.timingFunction = Motion.timingFunction
        layer.add(turn, forKey: "turn")
    }

    /// Whether the row is selected (`SimpleRowView` says): the rail's
    /// nodes fill with the selection's tint.
    var isSelectedRow: Bool {
        get { railView.isSelectedRow }
        set { railView.isSelectedRow = newValue }
    }

    // MARK: Layout

    /// The chevron's frame, in the cell's coordinates.
    private var disclosureFrame: CGRect {
        let size = Metrics.SimpleList.disclosureWidth
        let trailing = bounds.width - Metrics.CommitRow.selectionInset - Metrics.CommitRow.trailingPadding
        return CGRect(x: trailing - size, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    /// Where the disclosure chevron is, in the cell's coordinates: clicks
    /// there expand or collapse the merge.
    var disclosureRect: CGRect {
        guard content.isMerge else {
            return .zero
        }
        let width = Metrics.SimpleList.disclosureHitWidth
        return CGRect(x: disclosureFrame.midX - width / 2, y: 0, width: width, height: bounds.height)
    }

    override func layout() {
        super.layout()
        let metrics = Metrics.SimpleList.self
        let row = Metrics.CommitRow.self
        let height = bounds.height
        railView.frame = CGRect(x: row.selectionInset, y: 0, width: metrics.railWidth, height: height)

        // The avatar, or a merge's symbol in its circle.
        let avatar = row.rowAvatarSize
        let avatarX = railView.frame.maxX + row.spacing + (content.isIndented ? metrics.mergedIndent : 0)
        let avatarFrame = CGRect(x: avatarX, y: ((height - avatar) / 2).rounded(), width: avatar, height: avatar)
        avatarView.frame = avatarFrame
        mergeSymbol.frame = avatarFrame
        mergeSymbol.layer?.cornerRadius = AvatarClipShape.cornerRadius(Theme.current.avatarShape, side: avatar)
        mergeSymbol.layer?.backgroundColor = Palette.field.resolved(in: AppearanceVariant.of(effectiveAppearance)).cgColor
        let leading = avatarFrame.maxX + row.spacing

        // Right to left: the chevron's column, then the time.
        var trailing = bounds.width - row.selectionInset - row.trailingPadding
        if content.isMerge || keepsDisclosureColumn {
            disclosure.frame = disclosureFrame
            trailing -= metrics.disclosureWidth + row.spacing
        }
        timeLabel.frame = CGRect(
            x: trailing - row.timeWidth,
            y: ((height - Self.timeHeight) / 2).rounded(),
            width: row.timeWidth,
            height: Self.timeHeight
        )
        trailing = timeLabel.frame.minX - row.spacing

        // The title line (the tags, the title, the unpushed arrow), then
        // the meta line under it.
        let textTop = ((height - Self.summaryHeight - metrics.lineSpacing - Self.metaHeight) / 2).rounded()
        CommitRowParts.layoutTitleLine(
            refs: refsView,
            title: summaryLabel,
            titleWidth: summaryWidth,
            titleHeight: Self.summaryHeight,
            unpushed: unpushedArrow,
            leading: leading,
            trailing: trailing,
            midY: textTop + Self.summaryHeight / 2
        )
        let metaTop = textTop + Self.summaryHeight + metrics.lineSpacing
        metaLabel.frame = CGRect(x: leading, y: metaTop, width: min(metaWidth, max(trailing - leading, 0)), height: Self.metaHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Takes the current look's fonts and colors; the next configuration
    /// shows the content again in them.
    private func restyle() {
        styledLook = Look.current
        summaryLabel.font = AppKitTypography.row
        metaLabel.font = AppKitTypography.simpleMeta
        metaLabel.textColor = Palette.text3
        timeLabel.font = AppKitTypography.secondary
        timeLabel.textColor = Palette.text3
        unpushedArrow.contentTintColor = Palette.accent
        needsLayout = true
    }

    // MARK: Accessibility

    /// The row's actions, made when VoiceOver asks.
    var accessibilityActionsProvider: (() -> [NSAccessibilityCustomAction])?

    override func accessibilityLabel() -> String? {
        content.accessibilityLabel
    }

    override func accessibilityValue() -> Any? {
        guard content.isMerge else {
            return nil
        }
        return content.isExpanded ? "Expanded" : "Collapsed"
    }

    override func isAccessibilityExpanded() -> Bool {
        content.isExpanded
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        accessibilityActionsProvider?()
    }

    /// VoiceOver's Show Menu: the menu a right-click on the row shows.
    override func accessibilityPerformShowMenu() -> Bool {
        KeyboardContextMenu.showMenu(of: self)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.cancel()
        isSelectedRow = false
        // The next configuration applies in full, so an avatar that was
        // still loading loads again.
        content = SimpleRowContent()
    }
}

/// The line under an expanded merge's commits: they're loading, couldn't
/// load, or there are more than shown. The rail runs through it, and the
/// merge's stub fades out in it.
final class SimpleStatusCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SimpleStatus")

    private let railView = SimpleRailView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = AppKitTypography.simpleMeta
        label.textColor = Palette.text3
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(railView)
        addSubview(label)
        textField = label
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    /// Shows `text`, with `tooltip`, beside `rail`.
    func configure(_ text: String, tooltip: String?, rail: SimpleRail) {
        label.font = AppKitTypography.simpleMeta
        label.textColor = Palette.text3
        railView.rail = rail
        label.stringValue = text
        label.setTooltip(tooltip)
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let metrics = Metrics.SimpleList.self
        let row = Metrics.CommitRow.self
        railView.frame = CGRect(x: row.selectionInset, y: 0, width: metrics.railWidth, height: bounds.height)
        // Lined up with the merge's commits' titles.
        let leading = railView.frame.maxX + row.spacing + metrics.mergedIndent + row.rowAvatarSize + row.spacing
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(
            x: leading,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(bounds.width - leading - row.selectionInset - row.trailingPadding, 0),
            height: height
        )
    }
}

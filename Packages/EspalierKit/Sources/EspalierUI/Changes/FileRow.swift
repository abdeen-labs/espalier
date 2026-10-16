// A changed file's row in the Changes list: its checkbox (included,
// excluded, or partly), its status badge, its name and folder, a rename's
// old path, and the lines it adds and removes ("+10 −2"). A conflicted
// file's row has the warning (or, resolved, the check) for its badge, and
// at its end what's left to resolve and the conflict's buttons. A stash's
// files use the same row without the checkbox.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What a changed file's row shows.
nonisolated public struct FileRowContent: Sendable, Equatable, Identifiable {
    public var id: String
    /// The path, relative to the repository.
    public var path: String
    /// The old path of a rename or copy.
    public var oldPath: String?
    public var status: FileStatusKind
    /// Included in the next commit (true), excluded (false), or partly
    /// (nil: some lines).
    public var inclusion: Bool?
    /// Whether the checkbox can change (not while committing, not in a
    /// rebase's conflicts, not for a submodule with only uncommitted
    /// changes).
    public var isInclusionEnabled: Bool
    /// Why a submodule's checkbox is as it is.
    public var inclusionHelp: String?
    /// The lines the file's change adds and removes, once counted; nil while
    /// they load and for a file without counts (binary, a submodule,
    /// conflicted).
    public var lineCount: FileLineCount?
    /// Whether the row has a checkbox (a stash's files have none).
    public var showsCheckbox: Bool
    /// A conflicted file's state and what can be done with it, while an
    /// operation or a stash restore waits on its conflicts.
    public var conflict: ConflictFileRowContent?
    /// The format the line counts show in.
    public var numberFormat: NumberFormat

    public init(
        id: String,
        path: String,
        oldPath: String? = nil,
        status: FileStatusKind,
        inclusion: Bool?,
        isInclusionEnabled: Bool = true,
        inclusionHelp: String? = nil,
        lineCount: FileLineCount? = nil,
        showsCheckbox: Bool = true,
        conflict: ConflictFileRowContent? = nil,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.inclusion = inclusion
        self.isInclusionEnabled = isInclusionEnabled
        self.inclusionHelp = inclusionHelp
        self.lineCount = lineCount
        self.showsCheckbox = showsCheckbox
        self.conflict = conflict
        self.numberFormat = numberFormat
    }

    /// The file's name.
    public var fileName: String {
        POSIXPath.basename(path)
    }

    /// The folder the file is in, empty at the repository's root.
    public var directory: String {
        let directory = POSIXPath.dirname(path)
        return directory == "." ? "" : directory
    }

    /// A rename's or copy's source after the name: "← OldLoader.swift", or
    /// its whole path when it was in another folder.
    public var renameSource: String? {
        guard let oldPath else {
            return nil
        }
        let source = POSIXPath.dirname(oldPath) == POSIXPath.dirname(path) ? POSIXPath.basename(oldPath) : oldPath
        return "← \(source)"
    }

    /// How the checkbox reads to VoiceOver.
    public var inclusionDescription: String {
        switch inclusion {
        case true?: "Included"
        case false?: "Not included"
        case nil: "Partly included"
        }
    }

    /// The lines added and removed: "+10" and "−2" in `numberFormat` (zero
    /// counts left out; none without counts, or when the change adds and
    /// removes nothing).
    public var countParts: (added: String?, deleted: String?)? {
        guard let added = lineCount?.added, let deleted = lineCount?.deleted, added > 0 || deleted > 0 else {
            return nil
        }
        return (
            added > 0 ? "+\(formatCount(added, numberFormat))" : nil,
            deleted > 0 ? "\u{2212}\(formatCount(deleted, numberFormat))" : nil
        )
    }

    /// "+10 −2", as the row shows it, or nil.
    public var countsText: String? {
        countParts.map { [$0.added, $0.deleted].compactMap { $0 }.joined(separator: " ") }
    }

    /// The row as VoiceOver reads it: the name, the status, the folder, a
    /// rename's source, the lines added and removed, and a conflict's state.
    public var accessibilityLabel: String {
        var label = "\(fileName), \(status.title)"
        if !directory.isEmpty {
            label += ", in \(directory)"
        }
        if let oldPath {
            label += ", from \(oldPath)"
        }
        if countParts != nil, let added = lineCount?.added, let deleted = lineCount?.deleted {
            label += ", \(formatCount(added, numberFormat)) added lines, \(formatCount(deleted, numberFormat)) removed lines"
        }
        if let conflict {
            label += ", \(conflict.status)"
        }
        return label
    }

    /// The tooltip: the whole path, and a rename's source.
    public var help: String {
        oldPath.map { "\($0) → \(path)" } ?? path
    }
}

extension FileRowContent {
    /// The row for `file`, with its checkbox as the changes model shows it,
    /// its line counts once they've loaded (in `numberFormat`), and its
    /// conflict while it's conflicted.
    public init(
        _ file: WorkingDirectoryFileChange,
        inclusion: FileInclusionState,
        lineCount: FileLineCount? = nil,
        conflict: ConflictFileRowContent? = nil,
        numberFormat: NumberFormat
    ) {
        self.init(
            id: file.id,
            path: file.path,
            oldPath: file.status.oldPath,
            status: FileStatusKind(file.status),
            inclusion: inclusion.value,
            isInclusionEnabled: inclusion.isEnabled,
            inclusionHelp: inclusion.help,
            lineCount: lineCount,
            conflict: conflict,
            numberFormat: numberFormat
        )
    }

    /// The row for a file that can only be looked at (a stash's): no
    /// checkbox.
    public init(readOnly file: CommittedFileChange) {
        self.init(
            id: file.id,
            path: file.path,
            oldPath: file.status.oldPath,
            status: FileStatusKind(file.status),
            inclusion: nil,
            isInclusionEnabled: false,
            showsCheckbox: false
        )
    }
}

/// The Changes list's row metrics: file rows 30 high, inset 6 from the
/// column's edges, radius 9.
enum FileRowMetrics {
    /// The row's inset from the column's edges (its selection's too).
    static let inset: CGFloat = 6
    /// Space inside the row before its checkbox and after its last label.
    static let padding: CGFloat = 8
    /// Space between the checkbox, the badge, and the name.
    static let spacing: CGFloat = 9
    /// Space between the name, a rename's source, and the folder.
    static let labelSpacing: CGFloat = 6
    /// Space before the line counts, and before a conflict's buttons.
    static let countsSpacing: CGFloat = 8
    /// The share of the room after the badge a conflict's state keeps when
    /// the name would leave it less.
    static let conflictStatusShare: CGFloat = 0.35
    /// The row's leading content edge: the checkbox's x.
    static var contentInset: CGFloat {
        inset + padding
    }

    /// A conflict's buttons' trailing edge, from the row's: icon buttons
    /// carry their own room, so their symbols line up with the text.
    static var actionsInset: CGFloat {
        inset + Metrics.grid
    }
}

/// A changed file's row in the Changes table: the checkbox, the status
/// badge, the name, then a rename's source and the folder in tertiary
/// text (which give way first), and the line counts at the trailing edge
/// in SF Mono; for a conflicted file, its state and buttons at the
/// trailing edge instead. AppKit, so a table of 50,000 files configures
/// only the rows on screen.
final class FileRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("Espalier.FileRow")

    let checkbox = CheckboxButton(title: "", target: nil, action: nil)
    private let nameLabel = FileRowView.label(font: FileRowView.nameFont, color: Palette.text)
    private let sourceLabel = FileRowView.label(font: AppKitTypography.secondary, color: Palette.text3)
    private let directoryLabel = FileRowView.label(font: AppKitTypography.secondary, color: Palette.text3)
    private let countsLabel = FileRowView.label(font: AppKitTypography.count(), color: Palette.text3)
    private let glyph = StatusGlyphView()
    /// A conflicted file's warning, or its check once resolved, in the
    /// badge's place.
    private let conflictGlyph = NSImageView()
    /// A conflicted file's state: "3 conflicts", "Manual conflict".
    private let conflictLabel = FileRowView.label(font: AppKitTypography.secondary, color: Palette.text3)
    /// A conflicted file's buttons, made for the first conflict the row
    /// shows.
    private var conflictButtons: NSHostingView<ConflictFileButtons>?

    private(set) var content: FileRowContent?
    /// Includes (true) or excludes (false) the row's file.
    var onIncludeChanged: ((Bool) -> Void)?
    /// What a conflicted file's buttons do.
    private var conflictActions: ConflictFileRowActions?
    /// The row is fading out of the table: its file is gone, so it takes no
    /// clicks (they reach the table) and its checkbox does nothing.
    var isDeparting = false
    /// The repository whose file the row showed last.
    private var shownRepository: ObjectIdentifier?
    /// The look the row's fonts and colors are in.
    private var styledLook = Look.current

    /// The row's file departed: it stops answering while it fades out.
    func depart() {
        isDeparting = true
        onIncludeChanged = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDeparting ? nil : super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        // The table handles Space; the checkbox isn't a stop in the key
        // loop.
        checkbox.refusesFirstResponder = true
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        countsLabel.lineBreakMode = .byClipping
        countsLabel.isHidden = true
        directoryLabel.lineBreakMode = .byTruncatingHead
        conflictLabel.lineBreakMode = .byTruncatingTail
        conflictLabel.isHidden = true
        conflictGlyph.isHidden = true
        conflictGlyph.imageScaling = .scaleNone
        conflictGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: AppKitTypography.row.pointSize, weight: .regular)
        conflictGlyph.setAccessibilityElement(false)
        for view in [checkbox, glyph, conflictGlyph, nameLabel, sourceLabel, directoryLabel, countsLabel, conflictLabel] as [NSView] {
            addSubview(view)
        }
        textField = nameLabel
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The name's font: the row font, medium.
    static var nameFont: NSFont {
        AppKitTypography.row(weight: .medium)
    }

    /// Shows `content`, changing only what differs (a status pass refills
    /// every row on screen, most of them unchanged).
    ///
    /// - Parameters:
    ///   - repository: The repository the file is in: the same file's
    ///     checkbox animates its change, but a row reused for another file,
    ///     or for another repository's, shows its state at once.
    ///   - conflictActions: What a conflicted file's buttons do.
    func configure(_ content: FileRowContent, repository: ObjectIdentifier? = nil, conflictActions: ConflictFileRowActions? = nil) {
        let isSameRepository = repository == shownRepository
        shownRepository = repository
        self.conflictActions = conflictActions
        if styledLook != Look.current {
            restyle()
        }
        // The buttons follow the editor's setting, which the content
        // doesn't carry.
        if let conflict = content.conflict, let conflictActions, let conflictButtons {
            conflictButtons.rootView = ConflictFileButtons(content: conflict, actions: conflictActions)
        }
        guard content != self.content else {
            return
        }
        let isSameFile = isSameRepository && (self.content.map { ExactString($0.id) == ExactString(content.id) } ?? false)
        self.content = content
        let state = InclusionCheckbox.state(content.inclusion)
        if checkbox.isHidden == content.showsCheckbox {
            checkbox.isHidden = !content.showsCheckbox
        }
        if checkbox.state != state {
            checkbox.setState(state, animated: isSameFile)
        }
        if checkbox.isEnabled != content.isInclusionEnabled {
            checkbox.isEnabled = content.isInclusionEnabled
        }
        checkbox.setTooltip(content.inclusionHelp)
        checkbox.setAccessibilityLabel("Include \(content.fileName)")
        Self.set(nameLabel, content.fileName)
        nameLabel.setTooltip(content.help)
        Self.set(sourceLabel, content.renameSource ?? "")
        Self.set(directoryLabel, content.directory)
        setCounts(content.conflict == nil ? content.countParts : nil)
        glyph.kind = content.status
        showConflict(content.conflict)
        setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityValue(content.showsCheckbox ? content.inclusionDescription : nil)
        setAccessibilityCustomActions(accessibilityActions(for: content))
        needsLayout = true
    }

    /// Shows a conflicted file's glyph, state, and buttons in place of the
    /// badge and the counts, or hides them.
    private func showConflict(_ conflict: ConflictFileRowContent?) {
        guard let conflict else {
            glyph.isHidden = false
            conflictGlyph.isHidden = true
            Self.set(conflictLabel, "")
            conflictButtons?.isHidden = true
            return
        }
        glyph.isHidden = true
        conflictGlyph.isHidden = false
        conflictGlyph.image = NSImage(
            systemSymbolName: conflict.isUnresolved ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            accessibilityDescription: nil
        )
        conflictGlyph.contentTintColor = conflict.isUnresolved ? Palette.warningMark : Palette.success
        Self.set(conflictLabel, conflict.status)
        conflictLabel.textColor = conflict.isUnresolved ? Palette.warning : Palette.text3
        conflictLabel.setTooltip(conflict.status)
        let actions = conflictActions ?? ConflictFileRowActions(isEditorAvailable: false)
        let buttons = ConflictFileButtons(content: conflict, actions: actions)
        if let conflictButtons {
            conflictButtons.rootView = buttons
            conflictButtons.isHidden = false
        } else {
            let host = NSHostingView(rootView: buttons)
            // Its size is its buttons'; the row places it.
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            conflictButtons = host
        }
    }

    /// VoiceOver's actions: including or excluding the file, and a
    /// conflicted file's buttons.
    private func accessibilityActions(for content: FileRowContent) -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        if content.showsCheckbox {
            actions.append(NSAccessibilityCustomAction(name: content.inclusion == true ? "Exclude" : "Include") { [weak self] in
                guard let content = self?.content, content.isInclusionEnabled else {
                    return false
                }
                self?.onIncludeChanged?(content.inclusion != true)
                return true
            })
        }
        if let conflict = content.conflict, let conflictActions {
            for (index, item) in conflict.accessibilityActions(conflictActions).enumerated() {
                actions.append(NSAccessibilityCustomAction(name: item.name) { [weak self] in
                    self?.performConflictAction(at: index) ?? false
                })
            }
        }
        return actions
    }

    /// Runs a conflicted file's VoiceOver action, as the row shows it now.
    private func performConflictAction(at index: Int) -> Bool {
        guard let conflict = content?.conflict, let conflictActions else {
            return false
        }
        let items = conflict.accessibilityActions(conflictActions)
        guard items.indices.contains(index) else {
            return false
        }
        items[index].perform()
        return true
    }

    // MARK: Accessibility

    /// Whether the row is selected.
    override func isAccessibilitySelected() -> Bool {
        guard let (table, row) = enclosingTableRow else {
            return false
        }
        return table.isRowSelected(row)
    }

    /// VoiceOver and Accessibility Inspector select a file by setting its
    /// cell's AXSelected: the row alone is selected, as a click selects it,
    /// and the table tells the changes model (`FileTableCoordinator`).
    override func setAccessibilitySelected(_ selected: Bool) {
        guard selected, !isDeparting, let (table, row) = enclosingTableRow else {
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// VoiceOver's Show Menu: the menu a right-click on the row shows.
    override func accessibilityPerformShowMenu() -> Bool {
        KeyboardContextMenu.showMenu(of: self)
    }

    /// Takes the current look's fonts and colors, and shows the content
    /// again in them.
    private func restyle() {
        styledLook = Look.current
        nameLabel.font = Self.nameFont
        for label in [sourceLabel, directoryLabel, conflictLabel] {
            label.font = AppKitTypography.secondary
        }
        countsLabel.font = AppKitTypography.count()
        conflictGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: AppKitTypography.row.pointSize, weight: .regular)
        nameLabel.textColor = Palette.text
        for label in [sourceLabel, directoryLabel, countsLabel, conflictLabel] {
            label.textColor = Palette.text3
        }
        glyph.lookDidChange()
        // Shown again in full, in the new fonts and colors.
        content = nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // A selected row is the accent's soft wash, never solid, so the
            // labels keep their colors.
            nameLabel.textColor = Palette.text
            sourceLabel.textColor = Palette.text3
            directoryLabel.textColor = Palette.text3
        }
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let box = CheckboxDrawing.size
        checkbox.frame = CGRect(x: FileRowMetrics.contentInset, y: ((bounds.height - box) / 2).rounded(), width: box, height: box)
        let glyphSize = Metrics.FileList.statusGlyphSize
        let glyphX = checkbox.isHidden ? FileRowMetrics.contentInset : checkbox.frame.maxX + FileRowMetrics.spacing
        glyph.frame = CGRect(x: glyphX, y: ((bounds.height - glyphSize) / 2).rounded(), width: glyphSize, height: glyphSize)
        conflictGlyph.frame = glyph.frame

        // The name, then the rename's source, then the folder, as
        // `FileLabelWidths` shares the room: the folder gives way first. A
        // label's frame includes its cell's padding (its intrinsic width
        // doesn't, and a frame that narrow truncates the text), so frames
        // start and sit closer by that padding for the text to keep the
        // spacing. The counts keep their width at the trailing edge; a
        // conflict's buttons keep theirs, and its state takes what the name
        // leaves, at least `conflictStatusShare` of the room.
        let padding = Self.labelPadding
        let gap = FileRowMetrics.labelSpacing - 2 * padding
        var x = glyph.frame.maxX + FileRowMetrics.spacing - padding
        var end = bounds.width - FileRowMetrics.contentInset + padding
        if let conflictButtons, !conflictButtons.isHidden {
            let size = conflictButtons.intrinsicContentSize
            let width = max(size.width, 0)
            let height = min(max(size.height, 0), bounds.height)
            conflictButtons.frame = CGRect(
                x: bounds.width - FileRowMetrics.actionsInset - width,
                y: ((bounds.height - height) / 2).rounded(),
                width: width,
                height: height
            )
            end = conflictButtons.frame.minX - FileRowMetrics.countsSpacing + padding
        }
        let labels = [nameLabel, sourceLabel, directoryLabel].filter { !$0.isHidden }
        let natural = labels.map(Self.fittingWidth)
        if !conflictLabel.isHidden {
            let room = max(end - x, 0)
            let left = room - (natural.first ?? 0) - FileRowMetrics.countsSpacing + 2 * padding
            let width = min(Self.fittingWidth(conflictLabel), max(left, (room * FileRowMetrics.conflictStatusShare).rounded()))
            let height = ceil(conflictLabel.intrinsicContentSize.height)
            conflictLabel.frame = CGRect(x: end - width, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            end = conflictLabel.frame.minX - FileRowMetrics.countsSpacing + 2 * padding
        }
        if !countsLabel.isHidden {
            let width = Self.fittingWidth(countsLabel)
            let height = ceil(countsLabel.intrinsicContentSize.height)
            countsLabel.frame = CGRect(x: end - width, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            end = countsLabel.frame.minX - FileRowMetrics.countsSpacing + 2 * padding
        }
        let widths = FileLabelWidths.widths(
            natural: natural,
            floors: labels.map { FileLabelWidths.floor(of: $0.stringValue, font: $0.font ?? AppKitTypography.secondary) + 2 * padding },
            room: end - x,
            gap: gap
        )
        // The labels share the name's baseline.
        let nameHeight = ceil(nameLabel.intrinsicContentSize.height)
        let nameY = ((bounds.height - nameHeight) / 2).rounded()
        let baseline = nameY + nameLabel.firstBaselineOffsetFromTop
        for (label, width) in zip(labels, widths) {
            let height = ceil(label.intrinsicContentSize.height)
            let y = label === nameLabel ? nameY : (baseline - label.firstBaselineOffsetFromTop).rounded()
            label.frame = CGRect(x: x, y: y, width: width, height: height)
            if width > 0 {
                x += width + gap
            }
        }
        if !countsLabel.isHidden {
            countsLabel.frame.origin.y = (baseline - countsLabel.firstBaselineOffsetFromTop).rounded()
        }
        if !conflictLabel.isHidden {
            conflictLabel.frame.origin.y = (baseline - conflictLabel.firstBaselineOffsetFromTop).rounded()
        }
    }

    /// Shows "+10" in the added color and "−2" in the removed color, or
    /// hides the counts.
    private func setCounts(_ parts: (added: String?, deleted: String?)?) {
        guard let parts else {
            if !countsLabel.isHidden {
                countsLabel.isHidden = true
                countsLabel.stringValue = ""
            }
            return
        }
        let font = AppKitTypography.count()
        let text = NSMutableAttributedString()
        if let added = parts.added {
            text.append(NSAttributedString(string: added, attributes: [.font: font, .foregroundColor: DiffColors.addedMarker]))
        }
        if let deleted = parts.deleted {
            if text.length > 0 {
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: deleted, attributes: [.font: font, .foregroundColor: DiffColors.deletedMarker]))
        }
        if countsLabel.attributedStringValue != text {
            countsLabel.attributedStringValue = text
        }
        if countsLabel.isHidden {
            countsLabel.isHidden = false
        }
    }

    override var isFlipped: Bool {
        true
    }

    /// The padding a label's cell keeps on each side of its text.
    private static let labelPadding: CGFloat = 2

    /// The width a label needs to show its text untruncated: its cell's
    /// size, which includes the padding.
    static func fittingWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width + 2 * labelPadding)
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let content, !isDeparting else {
            // A departing row's checkbox keeps the state it showed.
            sender.state = content.map { InclusionCheckbox.state($0.inclusion) } ?? .off
            return
        }
        // The model decides; show the current state until it does.
        sender.state = InclusionCheckbox.state(content.inclusion)
        onIncludeChanged?(content.inclusion != true)
    }

    /// Sets a label's text when it differs; an empty label hides.
    private static func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
        if label.isHidden != text.isEmpty {
            label.isHidden = text.isEmpty
        }
    }

    private static func label(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        return label
    }
}

/// A file's status badge: its letter in the status color on a 15% tint, 17
/// points square with radius 6, the AppKit twin of `StatusGlyph`, for table
/// rows. The letter is a label: measuring an attributed string built from a
/// Swift dictionary in `draw(_:)` intermittently crashed in CoreText (a nil
/// attribute when it copied the attributes).
final class StatusGlyphView: NSView {
    var kind: FileStatusKind = .modified {
        didSet {
            if kind != oldValue {
                apply()
            }
        }
    }

    fileprivate let letter = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        letter.alignment = .center
        letter.setAccessibilityElement(false)
        addSubview(letter)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    private func apply() {
        letter.stringValue = kind.letter
        letter.textColor = Palette.statusForeground(kind)
        letter.font = Self.font
        setTooltip(kind.title)
        needsLayout = true
        needsDisplay = true
    }

    /// SF Mono 9.5, bold (heavy with Increase Contrast), as `StatusGlyph`.
    private static var font: NSFont {
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return FontFallback.checked(.monospacedSystemFont(ofSize: 9.5, weight: increased ? .heavy : .bold), size: 9.5, design: .mono)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Increase Contrast changes the appearance.
        letter.font = Self.font
    }

    override func layout() {
        super.layout()
        let height = ceil(letter.intrinsicContentSize.height)
        letter.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.statusBackground(kind).setFill()
        let radius = min(Metrics.StatusBadge.radius, bounds.height / 2)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

/// A checkbox that can be mixed, as a partly included file's is: Espalier's
/// `CheckboxButton`, since a SwiftUI toggle can't show a mixed state for
/// one value. Its title is part of it (a click on the title toggles too),
/// and changes at once.
///
/// Clicking it includes everything unless everything is included, as
/// clicking a mixed checkbox turns it on.
struct InclusionCheckbox: NSViewRepresentable {
    var value: Bool?
    var isEnabled = true
    /// The checkbox's title, after the box.
    var title = ""
    /// The title's font; the row font when nil.
    var titleFont: NSFont?
    /// What the checkbox is for (the repository): its state animates only
    /// while this stays the same, so choosing another repository shows its
    /// state at once.
    var scope: ObjectIdentifier?
    var onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CheckboxButton {
        let button = CheckboxButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        // The list handles Space; the checkbox isn't a stop in the key loop.
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: button, isEnabled: isEnabled && context.environment.isEnabled)
        context.coordinator.shownScope = scope
        return button
    }

    func updateNSView(_ button: CheckboxButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let isSameScope = coordinator.shownScope == scope
        coordinator.shownScope = scope
        apply(to: button, isEnabled: isEnabled && context.environment.isEnabled, animated: isSameScope)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CheckboxButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        guard let width = proposal.width, !title.isEmpty else {
            return size
        }
        return CGSize(width: min(size.width, width), height: size.height)
    }

    /// - Parameter isEnabled: Whether the checkbox takes clicks: `isEnabled`
    ///   where the environment's is too, since SwiftUI sets the
    ///   environment's on the control as it updates it.
    private func apply(to button: CheckboxButton, isEnabled: Bool, animated: Bool = false) {
        let state = Self.state(value)
        if button.state != state {
            button.setState(state, animated: animated)
        }
        if button.isEnabled != isEnabled {
            button.isEnabled = isEnabled
        }
        let font = titleFont ?? AppKitTypography.row
        if button.title != title || button.font != font {
            button.font = font
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.text])
        }
    }

    static func state(_ value: Bool?) -> NSControl.StateValue {
        CheckboxState(value).controlState
    }

    final class Coordinator: NSObject {
        var parent: InclusionCheckbox
        /// The scope the checkbox showed last.
        var shownScope: ObjectIdentifier?

        init(_ parent: InclusionCheckbox) {
            self.parent = parent
        }

        @objc func toggle(_ sender: NSButton) {
            let include = parent.value != true
            // The model decides; show the current state until it does.
            sender.state = InclusionCheckbox.state(parent.value)
            parent.onChange(include)
        }
    }
}

extension FileRowView: LookChangeObserving {
    func lookDidChange() {
        guard let content else {
            return
        }
        restyle()
        configure(content, repository: shownRepository, conflictActions: conflictActions)
    }
}

extension StatusGlyphView: LookChangeObserving {
    func lookDidChange() {
        letter.textColor = Palette.statusForeground(kind)
        needsDisplay = true
    }
}

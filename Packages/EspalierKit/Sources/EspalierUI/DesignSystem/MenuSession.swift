// An open menu: its card and any open submenus' cards, each in an
// `AnchoredPanel`, and how the mouse and keyboard drive them. One menu is
// open at a time.
//
// `MenuEventRouter` reads the app's events through one local monitor
// while a menu is open, so the window keeps its first responder and the
// menu's panels never become key. The mouse: hover highlights; a click
// opens the menu and a second click chooses, or a press that opened it
// drags to an item and releases on it; a click outside closes the menu
// and does nothing else, but a right-click on a context menu's view opens
// that menu instead. A submenu opens after a short hover or with →, and a
// pointer heading for an open submenu across other items keeps it open.
// The keyboard: ↑ and ↓ (past disabled items, dividers, and headers),
// Home and End, → and ←, Return and Space choose, Escape closes one
// level, and typing selects by a title's start. The router also opens
// context menus for a right-click or Control-click on a view that has one
// (`ContextMenuCard.swift`), and drives an open suggestion list
// (`SuggestionList.swift`).
//
// VoiceOver sees each card as a menu of menu items, with their checks,
// disabled state, and submenus; it hears the menu open and can choose
// items.

import AppKit
import SwiftUI

/// An open menu.
@MainActor
final class MenuSession {
    /// The menu that's open, if any.
    private(set) static var current: MenuSession?

    let request: MenuRequest
    /// The root card, then each open submenu's.
    private(set) var levels: [MenuLevelWindow] = []
    private(set) var isOpen = false
    /// How long the pointer rests on a submenu's item before it opens;
    /// zero opens it at once.
    var submenuDelay = Timing.submenuHover

    /// The mouse press that opened the menu is still down.
    private var isOpeningPress = false
    /// Where a press that's down began, and whether the pointer has moved
    /// away from there.
    private var pressStart: CGPoint?
    private var pressMoved = false
    /// The pointer's last place, on screen.
    private var lastPointer: CGPoint?
    private var submenuTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    /// Type-to-select's prefix and when it was last typed to.
    private var typedPrefix = ""
    private var typedAt: TimeInterval = 0

    private init(request: MenuRequest) {
        self.request = request
    }

    /// Opens `request`'s menu, closing any other first.
    ///
    /// - Returns: The open menu; nil when there's nothing to show or its
    ///   view isn't in a window.
    @discardableResult
    static func open(_ request: MenuRequest) -> MenuSession? {
        current?.close(animated: false)
        let content = request.content.tidied
        guard let view = request.view, view.window != nil, !content.isEmpty else {
            request.onClose?()
            return nil
        }
        let session = MenuSession(request: request)
        current = session
        session.start(content: content, in: view)
        MenuEventRouter.shared.install()
        return session
    }

    private func start(content: MenuContent, in view: NSView) {
        isOpen = true
        let root = MenuLevelWindow(content: content, minimumWidth: request.minimumWidth, parentRow: nil, label: request.label, session: self)
        levels = [root]
        let placement: AnchoredPanel.Placement
        let anchor: CGRect
        switch request.placement {
        case .below(let rect):
            anchor = rect
            placement = AnchoredPanel.Placement(edge: .below, alignment: .leading, gap: Metrics.Menu.gap)
        case .at(let point):
            anchor = CGRect(origin: point, size: .zero)
            placement = AnchoredPanel.Placement(edge: .point)
        }
        root.show(anchor: anchor, in: view, placement: placement)
        let trigger = request.trigger == .automatic ? MenuTrigger.current : request.trigger
        switch trigger {
        case .press:
            isOpeningPress = true
            pressStart = NSEvent.mouseLocation
        case .keyboard, .accessibility, .automatic:
            let level = root.level
            level.highlighted = level.checkedID.flatMap { level.row($0)?.isSelectable == true ? $0 : nil } ?? level.selectableIDs.first
        }
        root.container.announceOpened()
    }

    /// Closes the menu and its submenus.
    func close(animated: Bool = true) {
        guard isOpen else {
            return
        }
        isOpen = false
        submenuTask?.cancel()
        settleTask?.cancel()
        let root = levels.first
        for level in levels.reversed() {
            level.panel.onClose = nil
            level.panel.close(reason: .closed, animated: animated && level === root)
        }
        root?.container.announceClosed()
        levels = []
        if Self.current === self {
            Self.current = nil
        }
        request.onClose?()
    }

    /// Closes the menu if `view`, a view menus open from, left its window.
    static func anchorDidMove(_ view: NSView) {
        guard let current, current.request.view === view, view.window == nil || view.window !== current.levels.first?.parentWindow else {
            return
        }
        current.close(animated: false)
    }

    // MARK: Events

    /// What a menu did with an event.
    enum EventResult: Equatable {
        /// Used up: nothing else sees it.
        case consumed
        /// Left for the app to handle as usual.
        case passed
        /// A click outside closed the menu; a context click goes on to
        /// open the context menu under it.
        case closedByClick
    }

    /// Handles an event of the app's while the menu is open.
    @discardableResult
    func handle(_ event: NSEvent) -> EventResult {
        guard isOpen else {
            return .passed
        }
        switch event.type {
        case .keyDown:
            handleKey(event)
            return .consumed
        case .keyUp:
            return .consumed
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pointerMoved(to: Self.screenLocation(of: event))
            return .consumed
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return mouseDown(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return mouseUp(event)
        case .scrollWheel:
            return hit(Self.screenLocation(of: event)) == nil ? .consumed : .passed
        default:
            return .passed
        }
    }

    /// An event's place on screen.
    static func screenLocation(of event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Whether `event` asks for a context menu: a right-click, or a
    /// Control-click.
    static func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    /// The level whose card is at `point` (on screen), deepest first, and
    /// the row there.
    func hit(_ point: CGPoint) -> (level: Int, row: Int?)? {
        for index in levels.indices.reversed() where levels[index].cardFrame.contains(point) {
            return (index, levels[index].rowID(atScreen: point))
        }
        return nil
    }

    private func mouseDown(_ event: NSEvent) -> EventResult {
        let point = Self.screenLocation(of: event)
        guard let hit = hit(point) else {
            close()
            return Self.isContextClick(event) ? .closedByClick : .consumed
        }
        isOpeningPress = false
        pressStart = point
        pressMoved = true
        if let row = hit.row {
            highlight(row, in: hit.level, submenu: .now)
        }
        return .consumed
    }

    private func mouseUp(_ event: NSEvent) -> EventResult {
        let point = Self.screenLocation(of: event)
        let wasOpeningPress = isOpeningPress
        isOpeningPress = false
        pressStart = nil
        let isInMenu = event.window.map { window in levels.contains { $0.panel === window } } ?? false
        defer {
            pressMoved = false
        }
        if let hit = hit(point), let row = hit.row, let item = levels[hit.level].level.row(row)?.item, item.isEnabled {
            // The press that opened the menu, released where it began,
            // leaves the menu open; a submenu's item opened its submenu as
            // it was pressed or reached.
            if (!wasOpeningPress || pressMoved), item.submenu == nil {
                activate(row, in: hit.level)
            }
        } else if wasOpeningPress, pressMoved, hit(point) == nil, !isOverOpeningView(point) {
            close()
        }
        return isInMenu ? .consumed : .passed
    }

    /// Whether `point` (on screen) is over the view the menu opened from.
    private func isOverOpeningView(_ point: CGPoint) -> Bool {
        guard let view = request.view, let window = view.window else {
            return false
        }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return frame.contains(point)
    }

    // MARK: Pointer

    private func pointerMoved(to point: CGPoint, ignoringHeading: Bool = false) {
        let previous = lastPointer
        lastPointer = point
        if let pressStart, hypot(point.x - pressStart.x, point.y - pressStart.y) > Metrics.Menu.dragThreshold {
            pressMoved = true
        }
        settleTask?.cancel()
        guard let hit = hit(point) else {
            submenuTask?.cancel()
            if let deepest = levels.last, deepest.level.openSubmenu == nil {
                deepest.level.highlighted = nil
            }
            return
        }
        // Heading for the open submenu across this level's other items
        // keeps it open; the item under the pointer takes the highlight
        // once the pointer rests.
        if !ignoringHeading, hit.level + 1 < levels.count, let previous,
           hit.row != levels[hit.level].level.openSubmenu,
           isHeading(from: previous, to: point, toward: levels[hit.level + 1]) {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: Timing.submenuSettle)
                guard !Task.isCancelled, let self, let pointer = lastPointer else {
                    return
                }
                pointerMoved(to: pointer, ignoringHeading: true)
            }
            return
        }
        let level = levels[hit.level].level
        guard let row = hit.row, level.row(row)?.isSelectable == true else {
            // Padding, a divider, a header, or a disabled item: an open
            // submenu stays while the pointer is on its level's padding.
            if hit.row != nil || level.openSubmenu == nil {
                submenuTask?.cancel()
                closeLevels(after: hit.level)
                level.highlighted = nil
            }
            return
        }
        highlight(row, in: hit.level, submenu: .afterHover)
    }

    /// When highlighting an item opens its submenu.
    private enum SubmenuOpening {
        case now, afterHover, never
    }

    /// Highlights `row` of level `index`, closing the submenus past it
    /// unless the row opened them, and opens the row's submenu as
    /// `submenu` says.
    private func highlight(_ row: Int, in index: Int, submenu: SubmenuOpening) {
        let level = levels[index].level
        guard level.row(row)?.isSelectable == true else {
            return
        }
        if level.openSubmenu != row {
            closeLevels(after: index)
        } else if index + 1 < levels.count {
            levels[index + 1].level.highlighted = nil
        }
        level.highlighted = row
        levels[index].container.selectionChanged()
        submenuTask?.cancel()
        guard submenu != .never, level.row(row)?.item?.submenu != nil, level.openSubmenu != row else {
            return
        }
        if submenu == .now || submenuDelay == .zero {
            openSubmenu(row, from: index, highlightsFirst: false)
            return
        }
        let delay = submenuDelay
        submenuTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, isOpen, index < levels.count, levels[index].level.highlighted == row else {
                return
            }
            openSubmenu(row, from: index, highlightsFirst: false)
        }
    }

    /// Whether the pointer moving from `start` to `end` heads for `submenu`'s
    /// card: `end` is inside the triangle from `start` to the card's near
    /// edge.
    private func isHeading(from start: CGPoint, to end: CGPoint, toward submenu: MenuLevelWindow) -> Bool {
        let card = submenu.cardFrame
        let edgeX = submenu.panel.openedEdge == .leading ? card.maxX : card.minX
        let top = CGPoint(x: edgeX, y: card.maxY)
        let bottom = CGPoint(x: edgeX, y: card.minY)
        func sign(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let d1 = sign(end, start, top)
        let d2 = sign(end, top, bottom)
        let d3 = sign(end, bottom, start)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    // MARK: Submenus

    /// Opens the submenu of `row` in level `index`.
    func openSubmenu(_ row: Int, from index: Int, highlightsFirst: Bool) {
        guard index < levels.count else {
            return
        }
        let parent = levels[index]
        guard let item = parent.level.row(row)?.item, item.isEnabled, let content = item.submenu?.tidied, !content.isEmpty,
              let rowFrame = parent.level.rowFrames[row] else {
            return
        }
        closeLevels(after: index)
        submenuTask?.cancel()
        parent.level.highlighted = row
        parent.level.openSubmenu = row
        let child = MenuLevelWindow(content: content, minimumWidth: 0, parentRow: row, label: item.title, session: self)
        levels.append(child)
        // Beside the parent card's edge, overlapping it a little, with the
        // first row level with the row that opened it: the row grown by the
        // cards' inset.
        let anchor = rowFrame.insetBy(dx: -Metrics.Menu.inset, dy: -Metrics.Menu.inset)
        child.show(anchor: anchor, in: parent.hosting, placement: AnchoredPanel.Placement(edge: .trailing, gap: -Metrics.Menu.submenuOverlap))
        if highlightsFirst {
            child.level.highlighted = child.level.selectableIDs.first
            child.container.selectionChanged()
        }
        child.container.announceOpened()
    }

    /// Closes the submenus past level `index`.
    private func closeLevels(after index: Int) {
        guard index + 1 < levels.count else {
            return
        }
        while levels.count > index + 1 {
            let level = levels.removeLast()
            level.panel.onClose = nil
            level.panel.close(reason: .closed, animated: false)
        }
        levels[index].level.openSubmenu = nil
    }

    // MARK: Choosing

    /// Chooses `row` of level `index`: opens its submenu, or closes the
    /// menu (and the popover it's in, for an item that closes it) and runs
    /// its action.
    func activate(_ row: Int, in index: Int) {
        guard index < levels.count, let item = levels[index].level.row(row)?.item, item.isEnabled else {
            return
        }
        switch item.action {
        case .submenu:
            if levels[index].level.openSubmenu == row, index + 1 < levels.count {
                let child = levels[index + 1]
                child.level.highlighted = child.level.selectableIDs.first
                child.container.selectionChanged()
            } else {
                openSubmenu(row, from: index, highlightsFirst: true)
            }
        case .run(let action):
            let closePopover = item.closesPopover ? request.closePopover : nil
            close()
            closePopover?()
            action()
        }
    }

    // MARK: Keyboard

    /// The level the keyboard acts on: the deepest with a highlight.
    private var focusedLevel: Int {
        levels.lastIndex { $0.level.highlighted != nil } ?? 0
    }

    private func handleKey(_ event: NSEvent) {
        let index = focusedLevel
        guard index < levels.count else {
            return
        }
        let level = levels[index].level
        switch event.keyCode {
        case KeyCode.escape:
            if levels.count > 1 {
                closeLevels(after: levels.count - 2)
            } else {
                close()
            }
        case KeyCode.downArrow:
            move(in: index) { ids, current in
                current.flatMap { ids.firstIndex(of: $0) }.map { min($0 + 1, ids.count - 1) } ?? 0
            }
        case KeyCode.upArrow:
            move(in: index) { ids, current in
                current.flatMap { ids.firstIndex(of: $0) }.map { max($0 - 1, 0) } ?? ids.count - 1
            }
        case KeyCode.home, KeyCode.pageUp:
            move(in: index) { _, _ in 0 }
        case KeyCode.end, KeyCode.pageDown:
            move(in: index) { ids, _ in ids.count - 1 }
        case KeyCode.rightArrow:
            if let row = level.highlighted, level.row(row)?.item?.submenu != nil {
                activate(row, in: index)
            }
        case KeyCode.leftArrow:
            if index > 0 {
                closeLevels(after: index - 1)
                levels[index - 1].container.selectionChanged()
            }
        case KeyCode.returnKey, KeyCode.enter:
            chooseHighlighted(in: index)
        case KeyCode.space where !isTyping(at: event.timestamp):
            chooseHighlighted(in: index)
        default:
            typeSelect(event, in: index)
        }
    }

    /// Moves level `index`'s highlight to the selectable row `target` picks
    /// from the selectable rows and the current one's ID.
    private func move(in index: Int, _ target: ([Int], Int?) -> Int) {
        let level = levels[index].level
        let ids = level.selectableIDs
        guard !ids.isEmpty else {
            return
        }
        let row = ids[target(ids, level.highlighted)]
        typedPrefix = ""
        highlight(row, in: index, submenu: .never)
        level.scrollTarget = row
    }

    private func chooseHighlighted(in index: Int) {
        if let row = levels[index].level.highlighted {
            activate(row, in: index)
        } else {
            close()
        }
    }

    /// Whether a type-to-select prefix is being typed at `time`.
    private func isTyping(at time: TimeInterval) -> Bool {
        !typedPrefix.isEmpty && time - typedAt < Self.typeSelectInterval
    }

    private static var typeSelectInterval: TimeInterval {
        let (seconds, attoseconds) = Timing.menuTypeSelect.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// Highlights the first item of level `index` whose title starts with
    /// what's been typed.
    private func typeSelect(_ event: NSEvent, in index: Int) {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
            return
        }
        if !isTyping(at: event.timestamp) {
            typedPrefix = ""
        }
        typedPrefix += characters
        typedAt = event.timestamp
        let level = levels[index].level
        let prefix = typedPrefix
        let match = level.rows.first { row in
            guard row.isSelectable, let title = row.item?.title else {
                return false
            }
            return title.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        if let match {
            highlight(match.id, in: index, submenu: .never)
            level.scrollTarget = match.id
        }
    }
}

// MARK: - A card's window

/// One card of an open menu: its level, the panel it's in, and the views
/// drawing it.
@MainActor
final class MenuLevelWindow {
    let level: MenuLevel
    let panel = AnchoredPanel(interaction: .menu)
    let container: MenuPanelView
    let hosting: NSHostingView<MenuCardRoot>
    /// The row of the level before that opened this one.
    let parentRow: Int?
    private(set) weak var parentWindow: NSWindow?

    init(content: MenuContent, minimumWidth: CGFloat, parentRow: Int?, label: String?, session: MenuSession) {
        level = MenuLevel(content: content, minimumWidth: minimumWidth)
        self.parentRow = parentRow
        hosting = NSHostingView(rootView: MenuCardRoot(level: level, motionSuppressed: false))
        hosting.sizingOptions = [.intrinsicContentSize]
        container = MenuPanelView(level: level, label: label)
        container.session = session
        container.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        panel.contentInsets = Metrics.Menu.shadowInsets
        panel.onClose = { [weak session] reason in
            if reason != .closed {
                session?.close(animated: false)
            }
        }
    }

    /// Shows the card at `anchor` in `view`, on `placement`'s side, as
    /// tall as the screen allows; taller content scrolls.
    func show(anchor: CGRect, in view: NSView, placement: AnchoredPanel.Placement) {
        guard let window = view.window else {
            return
        }
        parentWindow = window
        hosting.rootView = MenuCardRoot(level: level, motionSuppressed: !Motion.animates(view))
        let screenAnchor = window.convertToScreen(view.convert(anchor, to: nil))
        let visible = AnchoredPanel.visibleFrame(containing: screenAnchor, parent: window)
        let insets = Metrics.Menu.shadowInsets
        let tallest = visible.height - 2 * Metrics.Menu.screenMargin
        var size = hosting.fittingSize
        if size.height - insets.top - insets.bottom > tallest {
            level.scrollHeight = tallest
            size = hosting.fittingSize
        }
        size = CGSize(width: ceil(size.width), height: ceil(size.height))
        container.frame = CGRect(origin: .zero, size: size)
        hosting.frame = container.bounds
        panel.show(container, contentSize: size, anchor: anchor, in: view, placement: placement)
        level.growthAnchor = switch panel.openedEdge {
        case .above: .bottomLeading
        case .leading: .topTrailing
        default: .topLeading
        }
        container.layoutSubtreeIfNeeded()
    }

    /// The card's rect on screen, its shadow margin left out.
    var cardFrame: CGRect {
        panel.contentFrame
    }

    /// The row at `point` on screen.
    func rowID(atScreen point: CGPoint) -> Int? {
        let windowPoint = panel.convertPoint(fromScreen: point)
        return level.rowID(at: hosting.convert(windowPoint, from: nil))
    }

    /// A row's rect on screen.
    func screenFrame(ofRow id: Int) -> CGRect? {
        guard let frame = level.rowFrames[id] else {
            return nil
        }
        return panel.convertToScreen(hosting.convert(frame, to: nil))
    }
}

/// The card with the environment its panel gives it.
struct MenuCardRoot: View {
    let level: MenuLevel
    let motionSuppressed: Bool

    var body: some View {
        MenuCard(level: level)
            .environment(\.motionSuppressed, motionSuppressed)
            .lookFont()
    }
}

/// A card's panel view: it holds the card and is what VoiceOver sees, a
/// menu of menu items. Mouse events reach the session through
/// `MenuEventRouter`; the tracking area makes the panel get mouse moves
/// though it's never key.
@MainActor
final class MenuPanelView: NSView {
    let level: MenuLevel
    private let label: String?
    weak var session: MenuSession?
    private var elements: [Int: MenuItemElement] = [:]

    init(level: MenuLevel, label: String?) {
        self.level = level
        self.label = label
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .menu
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func accessibilityChildren() -> [Any]? {
        level.rows.compactMap { row in
            row.item == nil ? nil : element(for: row.id)
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        level.highlighted.flatMap { element(for: $0) }.map { [$0] } ?? []
    }

    override func accessibilityPerformCancel() -> Bool {
        session?.close()
        return true
    }

    /// The element for the item row `id`.
    func element(for id: Int) -> MenuItemElement? {
        if let element = elements[id] {
            return element
        }
        guard let item = level.row(id)?.item else {
            return nil
        }
        let element = MenuItemElement(row: id, item: item, panel: self)
        elements[id] = element
        return element
    }

    /// The index of this card among the open menu's.
    var levelIndex: Int? {
        session?.levels.firstIndex { $0.container === self }
    }

    /// Tells VoiceOver the menu opened.
    func announceOpened() {
        NSAccessibility.post(element: self, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))
        selectionChanged()
    }

    /// Tells VoiceOver the menu closed.
    func announceClosed() {
        NSAccessibility.post(element: self, notification: NSAccessibility.Notification(rawValue: "AXMenuClosed"))
    }

    /// Tells VoiceOver the highlight moved.
    func selectionChanged() {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if let highlighted = level.highlighted, let element = element(for: highlighted) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }
}

/// A menu item as VoiceOver sees it. AppKit asks for it on the main
/// thread.
nonisolated final class MenuItemElement: NSAccessibilityElement {
    let row: Int
    let isChecked: Bool
    private let isEnabled: Bool
    private let hasSubmenu: Bool
    private nonisolated(unsafe) weak var panel: MenuPanelView?

    @MainActor
    init(row: Int, item: MenuItem, panel: MenuPanelView) {
        self.row = row
        isChecked = item.isChecked == true
        isEnabled = item.isEnabled
        hasSubmenu = item.submenu != nil
        self.panel = panel
        super.init()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(item.subtitle ?? (item.isEnabled ? nil : item.tooltip))
        setAccessibilityEnabled(item.isEnabled)
        setAccessibilityParent(panel)
    }

    override func accessibilityFrame() -> NSRect {
        let (panel, row) = (panel, row)
        return MainActor.assumeIsolated {
            guard let panel, let window = panel.window, let frame = panel.level.rowFrames[row] else {
                return .zero
            }
            return window.convertToScreen(panel.convert(frame, to: nil))
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let (panel, row) = (panel, row)
        return MainActor.assumeIsolated {
            panel?.level.highlighted == row
        }
    }

    override func isAccessibilityFocused() -> Bool {
        isAccessibilitySelected()
    }

    override func accessibilityValue() -> Any? {
        isChecked ? "checked" : nil
    }

    override func accessibilityChildren() -> [Any]? {
        guard hasSubmenu else {
            return nil
        }
        let (panel, row) = (panel, row)
        let submenu: MenuPanelView? = MainActor.assumeIsolated {
            guard let panel, let session = panel.session, let index = panel.levelIndex,
                  index + 1 < session.levels.count, session.levels[index + 1].parentRow == row else {
                return nil
            }
            return session.levels[index + 1].container
        }
        return submenu.map { [$0] }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else {
            return false
        }
        let (panel, row) = (panel, row)
        return MainActor.assumeIsolated {
            guard let panel, let index = panel.levelIndex else {
                return false
            }
            panel.session?.activate(row, in: index)
            return true
        }
    }

    override func accessibilityPerformPick() -> Bool {
        accessibilityPerformPress()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        hasSubmenu && accessibilityPerformPress()
    }
}

// MARK: - Routing the app's events

/// Reads the app's events through one local monitor: an open menu's, an
/// open suggestion list's, and context clicks on views that have context
/// menus.
@MainActor
final class MenuEventRouter {
    static let shared = MenuEventRouter()

    private var monitor: Any?

    /// Starts reading events, once.
    func install() {
        guard monitor == nil else {
            return
        }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel, .keyDown, .keyUp,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let isUsed = MainActor.assumeIsolated {
                self.map { $0.handle(event) == nil } ?? false
            }
            return isUsed ? nil : event
        }
    }

    /// Handles `event`: the open menu takes what it reads, then an open
    /// suggestion list, and a context click on a view with a context menu
    /// opens it.
    ///
    /// - Returns: The event to dispatch as usual, or nil when it's used up.
    func handle(_ event: NSEvent) -> NSEvent? {
        if let session = MenuSession.current, session.isOpen {
            switch session.handle(event) {
            case .consumed:
                return nil
            case .passed:
                return event
            case .closedByClick:
                // The click that closed the menu does nothing else, but a
                // context click opens the context menu under it.
                ContextMenuRegions.openMenu(for: event)
                return nil
            }
        }
        if let list = SuggestionList.current, list.handle(event) == .consumed {
            return nil
        }
        if MenuSession.isContextClick(event), ContextMenuRegions.openMenu(for: event) {
            return nil
        }
        return event
    }
}

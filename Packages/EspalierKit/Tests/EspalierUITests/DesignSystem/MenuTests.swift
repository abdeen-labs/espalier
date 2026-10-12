// Espalier's menus: the keyboard (arrows past disabled items, dividers,
// and headers, Home and End, Return and Space, Escape, typing a title's
// start), the mouse (hover, click, press-drag-release, a click outside),
// submenus (→ and ←, hover, heading for an open one), choices, tidying,
// placement on screen, and what VoiceOver sees.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Menus") @MainActor
struct MenuTests {
    // MARK: Keyboard

    @Test("arrows skip disabled items, dividers, and headers; Home and End go to the ends; Return chooses and closes")
    func keyboardNavigation() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let session = try harness.open(MenuContent {
            MenuAction("Off") { chosen.append("Off") }.disabled(true)
            MenuSection("Remote") {
                MenuAction("Fetch") { chosen.append("Fetch") }
                MenuAction("Pull") { chosen.append("Pull") }.disabled(true)
                MenuAction("Push") { chosen.append("Push") }
            }
            MenuAction("Settings…") { chosen.append("Settings…") }
        })
        // Opened from the keyboard: the first item that can be chosen.
        #expect(try harness.highlightedRow(session) == harness.row("Fetch", in: session))
        harness.press(KeyCode.downArrow, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Push", in: session))
        harness.press(KeyCode.downArrow, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Settings…", in: session))
        harness.press(KeyCode.downArrow, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Settings…", in: session))
        harness.press(KeyCode.home, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Fetch", in: session))
        harness.press(KeyCode.upArrow, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Fetch", in: session))
        harness.press(KeyCode.end, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Settings…", in: session))
        harness.press(KeyCode.upArrow, in: session)
        harness.press(KeyCode.returnKey, in: session)
        #expect(chosen == ["Push"])
        #expect(!session.isOpen)
        #expect(MenuSession.current == nil)
    }

    @Test("Space chooses; Escape closes without choosing")
    func spaceAndEscape() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let first = try harness.open(MenuContent {
            MenuAction("Fetch") { chosen.append("Fetch") }
        })
        harness.press(KeyCode.space, characters: " ", in: first)
        #expect(chosen == ["Fetch"])
        #expect(!first.isOpen)

        let second = try harness.open(MenuContent {
            MenuAction("Fetch") { chosen.append("Fetch") }
        })
        harness.press(KeyCode.escape, in: second)
        #expect(!second.isOpen)
        #expect(chosen == ["Fetch"])
    }

    @Test("typing selects the first item whose title starts with what's typed; a pause starts over")
    func typeSelect() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        let session = try harness.open(MenuContent {
            MenuAction("Copy File Path") {}
            MenuAction("Copy Relative File Path") {}
            MenuAction("Cherry-pick") {}
            MenuAction("Revert Changes") {}
            MenuAction("Rename…") {}.disabled(true)
        })
        harness.press(0, characters: "c", at: 10, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Copy File Path", in: session))
        harness.press(0, characters: "h", at: 10.2, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Cherry-pick", in: session))
        harness.press(0, characters: "c", at: 12, in: session)
        harness.press(0, characters: "o", at: 12.1, in: session)
        harness.press(0, characters: "p", at: 12.2, in: session)
        harness.press(0, characters: "y", at: 12.3, in: session)
        harness.press(KeyCode.space, characters: " ", at: 12.4, in: session)
        harness.press(0, characters: "r", at: 12.5, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Copy Relative File Path", in: session))
        // A disabled item isn't selected.
        harness.press(0, characters: "r", at: 20, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Revert Changes", in: session))
        harness.press(0, characters: "e", at: 20.1, in: session)
        harness.press(0, characters: "n", at: 20.2, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Revert Changes", in: session))
    }

    // MARK: Mouse

    @Test("hover highlights an item but not a disabled one; a click on an item chooses it")
    func hoverAndClick() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let session = try harness.open(MenuContent {
            MenuAction("Fetch") { chosen.append("Fetch") }
            MenuAction("Pull") { chosen.append("Pull") }.disabled(true)
            MenuAction("Push") { chosen.append("Push") }
        }, trigger: .press)
        #expect(session.levels[0].level.highlighted == nil)
        #expect(harness.move(to: "Push", in: session) == .consumed)
        #expect(try harness.highlightedRow(session) == harness.row("Push", in: session))
        harness.move(to: "Pull", in: session)
        #expect(harness.highlightedRow(session) == nil)
        harness.click("Pull", in: session)
        #expect(session.isOpen)
        harness.click("Fetch", in: session)
        #expect(chosen == ["Fetch"])
        #expect(!session.isOpen)
    }

    @Test("the press that opened the menu, released in place, leaves it open; dragged to an item and released, it chooses the item")
    func pressDragRelease() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let content = MenuContent {
            MenuAction("Fetch") { chosen.append("Fetch") }
            MenuAction("Push") { chosen.append("Push") }
        }
        let clicked = try harness.open(content, trigger: .press)
        let start = harness.anchorCenter
        #expect(clicked.handle(harness.mouse(.leftMouseUp, at: start)) == .passed)
        #expect(clicked.isOpen)
        #expect(chosen.isEmpty)
        clicked.close(animated: false)

        let dragged = try harness.open(content, trigger: .press)
        dragged.handle(harness.mouse(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y - 10)))
        let push = try harness.center(of: "Push", in: dragged)
        dragged.handle(harness.mouse(.leftMouseDragged, at: push))
        #expect(try harness.highlightedRow(dragged) == harness.row("Push", in: dragged))
        dragged.handle(harness.mouse(.leftMouseUp, at: push))
        #expect(chosen == ["Push"])
        #expect(!dragged.isOpen)
    }

    @Test("a click outside closes the menu and does nothing else; a right-click on a view with a context menu opens that menu")
    func outsideClick() throws {
        let recorder = MenuRecorder()
        let (window, host) = hostInWindow(
            Color.clear
                .frame(width: 80, height: 40)
                .contextMenuCard {
                    MenuAction("Copy") {}
                }
                .environment(\.menuPresenter, recorder.menuPresenter)
                .frame(width: 300, height: 200, alignment: .bottomTrailing),
            size: CGSize(width: 300, height: 200)
        )
        defer { window.contentView = nil }
        let anchor = NSView(frame: CGRect(x: 10, y: 150, width: 80, height: 28))
        host.addSubview(anchor)
        let router = MenuEventRouter.shared

        let first = try #require(MenuSession.open(MenuRequest(content: MenuContent { MenuAction("Fetch") {} }, view: anchor, placement: .below(anchor.bounds), trigger: .keyboard)))
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 150, y: 150), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(router.handle(outside) == nil)
        #expect(!first.isOpen)
        #expect(recorder.popups.isEmpty)

        let second = try #require(MenuSession.open(MenuRequest(content: MenuContent { MenuAction("Fetch") {} }, view: anchor, placement: .below(anchor.bounds), trigger: .keyboard)))
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 260, y: 20), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(router.handle(rightClick) == nil)
        #expect(!second.isOpen)
        #expect(recorder.popups.count == 1)

        // With no menu open, a right-click elsewhere goes on as usual.
        let elsewhere = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 40, y: 20), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(router.handle(elsewhere) === elsewhere)
        // A Control-click opens the context menu as a right-click does.
        let controlClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 260, y: 20), modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(router.handle(controlClick) == nil)
        #expect(recorder.popups.count == 2)
    }

    @Test("an item that closes its popover closes it before it acts; one that doesn't leaves it")
    func closesPopover() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var events: [String] = []
        let content = MenuContent {
            MenuAction("Clone Repository…") { events.append("clone") }.closesPopover()
            MenuAction("Copy Repository Path") { events.append("copy") }
        }
        let close = ClosePopoverAction { events.append("close popover") }
        for title in ["Clone Repository…", "Copy Repository Path"] {
            let session = try #require(MenuSession.open(MenuRequest(content: content, view: harness.anchor, placement: .below(harness.anchor.bounds), trigger: .keyboard, closePopover: close)))
            harness.click(title, in: session)
        }
        #expect(events == ["close popover", "clone", "copy"])
    }

    @Test("the menu closes when its window moves or its view leaves the window")
    func closesWithItsWindow() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        let content = MenuContent { MenuAction("Fetch") {} }
        var closed = 0
        let moved = try #require(MenuSession.open(MenuRequest(content: content, view: harness.anchor, placement: .below(harness.anchor.bounds), trigger: .keyboard) { closed += 1 }))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: harness.window)
        #expect(!moved.isOpen)

        let anchor = MenuButtonAnchorView(frame: harness.anchor.frame)
        harness.window.contentView?.addSubview(anchor)
        let removed = try #require(MenuSession.open(MenuRequest(content: content, view: anchor, placement: .below(anchor.bounds), trigger: .keyboard) { closed += 1 }))
        anchor.removeFromSuperview()
        #expect(!removed.isOpen)
        #expect(closed == 2)
    }

    // MARK: Submenus

    @Test("→ opens a submenu with its first item highlighted, ← and Escape close it, and a disabled one doesn't open")
    func submenuKeyboard() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let session = try harness.open(MenuContent {
            Submenu("History Scope") {
                MenuAction("Current Branch") { chosen.append("Current Branch") }
                MenuAction("All Branches") { chosen.append("All Branches") }
            }
            Submenu("Delete Tag") {
                MenuAction("v1.0") {}
            }
            .disabled(true)
            MenuAction("Copy SHA") {}
        })
        #expect(try harness.highlightedRow(session) == harness.row("History Scope", in: session))
        harness.press(KeyCode.rightArrow, in: session)
        #expect(session.levels.count == 2)
        #expect(try harness.highlightedRow(session, level: 1) == harness.row("Current Branch", in: session, level: 1))
        harness.press(KeyCode.leftArrow, in: session)
        #expect(session.levels.count == 1)
        #expect(try harness.highlightedRow(session) == harness.row("History Scope", in: session))
        harness.press(KeyCode.returnKey, in: session)
        #expect(session.levels.count == 2)
        harness.press(KeyCode.escape, in: session)
        #expect(session.levels.count == 1)
        #expect(session.isOpen)
        harness.press(KeyCode.downArrow, in: session)
        #expect(try harness.highlightedRow(session) == harness.row("Copy SHA", in: session))
        harness.press(KeyCode.upArrow, in: session)
        harness.press(KeyCode.rightArrow, in: session)
        harness.press(KeyCode.downArrow, in: session)
        harness.press(KeyCode.returnKey, in: session)
        #expect(chosen == ["All Branches"])
        #expect(!session.isOpen)
    }

    @Test("hovering a submenu's item opens it; heading for it across other items keeps it open; moving elsewhere closes it")
    func submenuHover() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        let session = try harness.open(MenuContent {
            MenuAction("Above") {}
            Submenu("History Scope") {
                MenuAction("Current Branch") {}
                MenuAction("All Branches") {}
                MenuAction("Every Ref") {}
            }
            MenuAction("Below") {}
            MenuAction("Further Below") {}
        }, trigger: .press)
        session.submenuDelay = .zero
        harness.move(to: "Above", in: session)
        #expect(session.levels.count == 1)
        let scope = try harness.center(of: "History Scope", in: session)
        session.handle(harness.mouse(.mouseMoved, at: scope))
        #expect(session.levels.count == 2)
        #expect(try harness.highlightedRow(session) == harness.row("History Scope", in: session))

        // Down and toward the submenu, over Below: it stays open.
        let submenu = session.levels[1].cardFrame
        let below = try harness.center(of: "Below", in: session)
        let towardSubmenu = CGPoint(x: min(below.x + 30, submenu.minX - 2), y: below.y)
        session.handle(harness.mouse(.mouseMoved, at: towardSubmenu))
        #expect(session.levels.count == 2)
        #expect(try harness.highlightedRow(session) == harness.row("History Scope", in: session))

        // Back away from it, over Further Below: it closes.
        let further = try harness.center(of: "Further Below", in: session)
        session.handle(harness.mouse(.mouseMoved, at: CGPoint(x: further.x - 40, y: further.y)))
        #expect(session.levels.count == 1)
        #expect(try harness.highlightedRow(session) == harness.row("Further Below", in: session))
    }

    // MARK: Content

    @Test("a picker's choices check the selection and choosing one selects it")
    func choices() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var isSplit = false
        let selection = Binding(get: { isSplit }, set: { isSplit = $0 })
        let content = MenuContent {
            MenuPicker(selection: selection) {
                MenuChoice("Unified", value: false)
                MenuChoice("Split", value: true)
            }
            MenuDivider()
            MenuToggle("Wrap Lines", isOn: true) {}
        }
        #expect(content.items.map(\.isChecked) == [true, false, true])
        let session = try harness.open(content)
        harness.press(KeyCode.downArrow, in: session)
        harness.press(KeyCode.returnKey, in: session)
        #expect(isSplit)
    }

    /// A menu entry, written as a test case.
    enum EntrySpec: Sendable {
        case item(String), header(String), divider, option(String)

        @MainActor
        var entry: MenuContent.Entry {
            switch self {
            case .item(let title): .item(MenuItem(title, action: .run {}))
            case .header(let text): .header(text)
            case .divider: .divider
            case .option(let title): .option(MenuOption(title: title, value: AnyHashable(title), isEnabled: true))
            }
        }
    }

    /// A tidied entry, by kind.
    enum TidiedEntry: Sendable, Equatable {
        case item, disabledItem, header, divider
    }

    @Test("tidying drops leading, trailing, and repeated dividers and empty sections' headers", arguments: [
        NamedCase("leading and trailing dividers", ([EntrySpec.divider, .item("A"), .divider], [TidiedEntry.item])),
        NamedCase("repeated dividers", ([.item("A"), .divider, .divider, .item("B")], [.item, .divider, .item])),
        NamedCase("a header with nothing under it", ([.item("A"), .divider, .header("Empty"), .divider, .header("Full"), .item("B")], [.item, .divider, .header, .item])),
        NamedCase("a trailing header", ([.item("A"), .divider, .header("Empty")], [.item])),
        NamedCase("an unresolved choice", ([.option("Stray")], [.disabledItem])),
    ])
    func tidying(_ named: NamedCase<([EntrySpec], [TidiedEntry])>) {
        let (specs, expected) = named.value
        let entries = MenuContent(specs.map(\.entry)).tidied.entries.map { entry -> TidiedEntry in
            switch entry {
            case .item(let item): item.isEnabled ? .item : .disabledItem
            case .header: .header
            case .divider, .option: .divider
            }
        }
        #expect(entries == expected)
    }

    // MARK: Placement

    @Test("a panel opens on its side of the anchor, flips when there's no room, and shifts to stay on screen", arguments: [
        NamedCase("below, leading edges aligned", (AnchoredPanel.Placement(edge: .below, gap: 4), CGRect(x: 100, y: 500, width: 80, height: 28), CGPoint(x: 100, y: 296), AnchoredPanel.Edge.below)),
        NamedCase("above, without room below", (AnchoredPanel.Placement(edge: .below, gap: 4), CGRect(x: 100, y: 150, width: 80, height: 28), CGPoint(x: 100, y: 182), .above)),
        NamedCase("shifted in from the screen's right edge", (AnchoredPanel.Placement(edge: .below, gap: 4), CGRect(x: 950, y: 500, width: 40, height: 28), CGPoint(x: 1000 - 6 - 160, y: 296), .below)),
        NamedCase("at a point, below and right of it", (AnchoredPanel.Placement(edge: .point), CGRect(x: 300, y: 500, width: 0, height: 0), CGPoint(x: 300, y: 300), .point)),
        NamedCase("at a point near the bottom right, above and left of it", (AnchoredPanel.Placement(edge: .point), CGRect(x: 900, y: 100, width: 0, height: 0), CGPoint(x: 740, y: 100), .point)),
        NamedCase("beside, trailing", (AnchoredPanel.Placement(edge: .trailing, gap: -2), CGRect(x: 300, y: 600, width: 200, height: 24), CGPoint(x: 498, y: 624 - 200), .trailing)),
        NamedCase("beside, leading without room on the trailing side", (AnchoredPanel.Placement(edge: .trailing, gap: -2), CGRect(x: 700, y: 600, width: 200, height: 24), CGPoint(x: 542, y: 624 - 200), .leading)),
    ])
    func placement(_ named: NamedCase<(AnchoredPanel.Placement, CGRect, CGPoint, AnchoredPanel.Edge)>) {
        let (placement, anchor, origin, edge) = named.value
        let insets = NSEdgeInsets(top: 10, left: 20, bottom: 30, right: 20)
        let placed = AnchoredPanel.frame(
            contentSize: CGSize(width: 160 + 40, height: 200 + 40),
            insets: insets,
            anchor: anchor,
            placement: placement,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placed.edge == edge)
        #expect(CGPoint(x: placed.frame.minX + insets.left, y: placed.frame.minY + insets.bottom) == origin)
    }

    // MARK: VoiceOver

    @Test("VoiceOver sees an open menu of menu items, with their disabled state, and can choose one")
    func accessibility() throws {
        let harness = MenuHarness()
        defer { harness.tearDown() }
        var chosen: [String] = []
        let session = try harness.open(MenuContent {
            MenuToggle("Wrap Lines", isOn: true) {}
            MenuAction("Pull") {}.disabled(true)
            Submenu("History Scope") {
                MenuAction("All Branches") {}
            }
            MenuAction("Fetch") { chosen.append("Fetch") }
        })
        let menu = session.levels[0].container
        #expect(menu.accessibilityRole() == .menu)
        let items = try #require(menu.accessibilityChildren() as? [MenuItemElement])
        #expect(items.map { $0.accessibilityRole() } == Array(repeating: .menuItem, count: 4))
        #expect(!items[1].isAccessibilityEnabled())
        #expect(items[0].isAccessibilitySelected())
        #expect(items[0].accessibilityFrame() != .zero)
        #expect(items[2].accessibilityPerformShowMenu())
        #expect(session.levels.count == 2)
        #expect((items[2].accessibilityChildren()?.first as? MenuPanelView) === session.levels[1].container)
        #expect(items[3].accessibilityPerformPress())
        #expect(chosen == ["Fetch"])
    }
}

/// A window with a view a menu opens from, and events to drive the menu.
@MainActor
struct MenuHarness {
    let window: SnapshotWindow
    let anchor: NSView

    init() {
        window = SnapshotWindow(contentRect: CGRect(x: 200, y: 300, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = content
        anchor = NSView(frame: CGRect(x: 20, y: 340, width: 120, height: 28))
        content.addSubview(anchor)
    }

    func tearDown() {
        MenuSession.current?.close(animated: false)
        window.contentView = nil
    }

    /// Opens `content` below the anchor.
    func open(_ content: MenuContent, trigger: MenuTrigger = .keyboard) throws -> MenuSession {
        try #require(MenuSession.open(MenuRequest(content: content, view: anchor, placement: .below(anchor.bounds), trigger: trigger)))
    }

    /// The anchor's middle, on screen.
    var anchorCenter: CGPoint {
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The highlighted row's ID.
    func highlightedRow(_ session: MenuSession, level: Int = 0) -> Int? {
        session.levels[level].level.highlighted
    }

    /// The ID of the row of the item titled `title`.
    func row(_ title: String, in session: MenuSession, level: Int = 0) throws -> Int {
        try #require(session.levels[level].level.rows.first { $0.item?.title == title }?.id)
    }

    /// The middle of the item titled `title`, on screen.
    func center(of title: String, in session: MenuSession, level: Int = 0) throws -> CGPoint {
        let window = session.levels[level]
        let row = try #require(window.level.rows.first { $0.item?.title == title })
        let frame = try #require(window.screenFrame(ofRow: row.id))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A mouse event at `point` on screen, in no window.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @discardableResult
    func move(to title: String, in session: MenuSession) -> MenuSession.EventResult {
        guard let point = try? center(of: title, in: session) else {
            Issue.record("No item titled \(title)")
            return .passed
        }
        return session.handle(mouse(.mouseMoved, at: point))
    }

    func click(_ title: String, in session: MenuSession) {
        guard let point = try? center(of: title, in: session) else {
            Issue.record("No item titled \(title)")
            return
        }
        session.handle(mouse(.leftMouseDown, at: point))
        session.handle(mouse(.leftMouseUp, at: point))
    }

    /// A key press: `keyCode` with `characters`, at `time` (seconds).
    func press(_ keyCode: UInt16, characters: String = "", at time: TimeInterval = 0, in session: MenuSession) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: time,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        session.handle(event)
    }
}

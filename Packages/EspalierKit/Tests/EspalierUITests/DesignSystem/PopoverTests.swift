// Espalier's popovers: every way one closes sets its binding back (a click
// outside and Escape used up), an item's popover, ⌘T and ⌘B toggling theirs,
// key focus going in and coming back, what VoiceOver sees, menus opened in
// a popover taking its clicks and keys first and closing it before an item
// acts, a popover from a sheet's card floating above it, placement beside
// the anchor (flipped and shifted to stay on screen), and following the
// content's size. The windows are offscreen, so no panel is ordered in.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Popovers", .hangGuard(minutes: 5)) @MainActor
struct PopoverTests {
    // MARK: Closing

    /// A way a popover closes.
    enum ClosePath: Sendable {
        case outsideClick, escape, windowMoved, windowResized, anchorRemoved, appDeactivated, bindingCleared, closeAction
    }

    @Test("every way a popover closes sets its binding back; a click outside and Escape do nothing else", arguments: [
        NamedCase("a click outside", ClosePath.outsideClick),
        NamedCase("Escape", .escape),
        NamedCase("the window moving", .windowMoved),
        NamedCase("the window resizing", .windowResized),
        NamedCase("the anchor leaving the window", .anchorRemoved),
        NamedCase("Espalier going to the background", .appDeactivated),
        NamedCase("the binding set back", .bindingCleared),
        NamedCase("its content closing it", .closeAction),
    ])
    func closing(_ testCase: NamedCase<ClosePath>) throws {
        let state = PopoverState()
        let (window, host) = hostInWindow(Presenting(state: state), size: CGSize(width: 300, height: 200))
        defer { window.contentView = nil }
        let anchor = try #require(firstView(PopoverAnchorView.self, in: host))
        let presentation = try #require(anchor.presentation)
        state.isPresented = true
        presentation.sync()
        let controller = try #require(presentation.controller)
        #expect(controller.isOpen)
        #expect(controller.panel.anchorWindow === window)

        switch testCase.value {
        case .outsideClick:
            #expect(controller.panel.handleClosingEvent(try mouseDown(at: CGPoint(x: 250, y: 20), in: window)))
        case .escape:
            #expect(controller.panel.handleClosingEvent(try escape(in: window)))
        case .windowMoved:
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        case .windowResized:
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        case .anchorRemoved:
            // The window's next update finds it gone.
            anchor.removeFromSuperview()
            controller.panel.closeIfAnchorRemoved()
        case .appDeactivated:
            controller.panel.close(reason: .appDeactivated, animated: false)
        case .bindingCleared:
            state.isPresented = false
            presentation.sync()
        case .closeAction:
            controller.model.closeAction?()
        }
        #expect(!controller.isOpen)
        #expect(!state.isPresented)
        #expect(presentation.controller == nil)
    }

    @Test("an item's popover shows while the item is set, another item replaces its content, and closing it clears the item")
    func itemPopover() throws {
        let state = PopoverState()
        let (window, host) = hostInWindow(PresentingItem(state: state), size: CGSize(width: 300, height: 200))
        defer { window.contentView = nil }
        let presentation = try #require(firstView(PopoverAnchorView.self, in: host)?.presentation)
        state.tab = .unreachable
        presentation.sync()
        let controller = try #require(presentation.controller)
        state.tab = .reachable
        presentation.sync()
        #expect(presentation.controller === controller)
        #expect(controller.isOpen)
        #expect(controller.panel.handleClosingEvent(try escape(in: window)))
        #expect(state.tab == nil)
        #expect(presentation.controller == nil)
    }

    @Test("⌘T and ⌘B open their popovers and close them while they're open", .offline)
    func shortcutsToggle() async throws {
        let fixture = try await WorktreeUIFixture.make()
        let context = fixture.context
        let toggles: [(ActionID, KeyPath<WindowState, Bool>)] = [
            (.switchRepository, \.isRepositoryPopoverPresented),
            (.switchBranch, \.isBranchPopoverPresented),
        ]
        for (action, isPresented) in toggles {
            await context.actions.performAndWait(action)
            #expect(context.state[keyPath: isPresented])
            await context.actions.performAndWait(action)
            #expect(!context.state[keyPath: isPresented])
        }
    }

    // MARK: Focus

    @Test("a popover with a field becomes key and gives key focus back as it closes, unless another window took it")
    func keyFocus() throws {
        let harness = PopoverHarness()
        defer { harness.tearDown() }
        let recorder = FocusRecorder()
        recorder.keyWindow = harness.window
        let first = harness.show(recorder) {
            FilterField()
        }
        #expect(recorder.madeKey == [first.panel])
        first.close()
        #expect(recorder.madeKey == [first.panel, harness.window])

        let second = harness.show(recorder) {
            FilterField()
        }
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        recorder.keyWindow = other
        second.close()
        #expect(recorder.madeKey == [first.panel, harness.window, second.panel])
    }

    @Test("a popover without a field opened with a click leaves the window key; opened from the keyboard or with VoiceOver on, it becomes key", arguments: [
        NamedCase("a click", (false, false, false)),
        NamedCase("the keyboard", (true, false, true)),
        NamedCase("VoiceOver", (false, true, true)),
    ])
    func keyFocusWithoutField(_ testCase: NamedCase<(Bool, Bool, Bool)>) throws {
        let (keyboard, voiceOver, becomesKey) = testCase.value
        let harness = PopoverHarness()
        defer { harness.tearDown() }
        let recorder = FocusRecorder()
        recorder.keyWindow = harness.window
        recorder.openedByKeyboard = keyboard
        recorder.voiceOver = voiceOver
        let controller = harness.show(recorder) {
            Text("Great commit summaries are under 50 characters")
                .padding(Metrics.Popover.padding)
        }
        let opened: [NSWindow] = becomesKey ? [controller.panel] : []
        #expect(recorder.madeKey == opened)
        controller.close()
        let closed: [NSWindow] = becomesKey ? [controller.panel, harness.window] : []
        #expect(recorder.madeKey == closed)
    }

    @Test("VoiceOver sees a popover named by its title, moves into it as it opens and back to the anchor as it closes, and can close it")
    func accessibility() throws {
        let harness = PopoverHarness()
        defer { harness.tearDown() }
        let recorder = FocusRecorder()
        let controller = harness.show(recorder, title: "Commit Reachability") {
            Text("2 commits not included.")
                .padding(Metrics.Popover.padding)
        }
        #expect(controller.container.accessibilityRole() == .popover)
        #expect(controller.container.accessibilityLabel() == "Commit Reachability")
        #expect(recorder.accessibilityFocus.count == 1)
        #expect(recorder.accessibilityFocus.first === controller.container)
        controller.close()
        #expect(recorder.accessibilityFocus.count == 2)
        #expect(recorder.accessibilityFocus.last !== controller.container)

        let cancelled = harness.show {
            Text("Checks").padding(Metrics.Popover.padding)
        }
        #expect(cancelled.container.accessibilityPerformCancel())
        #expect(!cancelled.isOpen)
    }

    // MARK: Menus and modals

    @Test("a menu opened in a popover is anchored in it and takes its clicks and keys first; an item that closes the popover closes it before acting")
    func menuInPopover() throws {
        let harness = PopoverHarness()
        defer { harness.tearDown() }
        var events: [String] = []
        let controller = harness.show {
            PullDownButton("Add") {
                MenuAction("Clone Repository…") { events.append("clone") }.closesPopover()
            } label: {
                Text("Add")
            }
            .padding(Metrics.Popover.padding)
        }
        controller.onClose = { _ in events.append("closed") }
        let button = try #require(firstView(MenuButtonAnchorView.self, in: controller.container))
        #expect(button.accessibilityPerformPress())
        let session = try #require(MenuSession.current)
        let menu = try #require(session.levels.first)
        #expect(menu.panel.anchorWindow === controller.panel)
        #expect(menu.panel.level.rawValue >= controller.panel.level.rawValue)

        #expect(!controller.panel.handleClosingEvent(try mouseDown(at: CGPoint(x: 20, y: 20), in: harness.window)))
        #expect(!controller.panel.handleClosingEvent(try escape(in: harness.window)))
        #expect(controller.isOpen)

        let item = try #require(menu.level.highlighted)
        session.activate(item, in: 0)
        #expect(events == ["closed", "clone"])
        #expect(!controller.isOpen)
        #expect(!session.isOpen)
    }

    @Test("a popover from a sheet's card is anchored in the card's panel, floats above it, and takes Escape before it")
    func aboveModalCard() throws {
        let state = PopoverState()
        let panel = ModalLayerPanel()
        panel.setFrame(CGRect(x: 100, y: 100, width: 400, height: 300), display: false)
        let host = NSHostingView(rootView: Snapshot.deterministic(Presenting(state: state)))
        panel.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        defer { panel.contentView = nil }
        let presentation = try #require(firstView(PopoverAnchorView.self, in: host)?.presentation)
        state.isPresented = true
        presentation.sync()
        let controller = try #require(presentation.controller)
        #expect(controller.panel.anchorWindow === panel)
        #expect(controller.panel.level.rawValue > panel.level.rawValue)
        #expect(controller.panel.handleClosingEvent(try escape(in: panel)))
        #expect(!state.isPresented)
    }

    // MARK: Placement and size

    @Test("a popover opens centered on its anchor's edge, flips when there's no room, and shifts to stay on screen", arguments: [
        NamedCase("below", (AnchoredPanel.Placement(edge: .below, alignment: .center, gap: 6), CGRect(x: 400, y: 500, width: 200, height: 28), CGPoint(x: 420, y: 294), AnchoredPanel.Edge.below)),
        NamedCase("above, without room below", (AnchoredPanel.Placement(edge: .below, alignment: .center, gap: 6), CGRect(x: 400, y: 150, width: 200, height: 28), CGPoint(x: 420, y: 184), .above)),
        NamedCase("above", (AnchoredPanel.Placement(edge: .above, alignment: .center, gap: 6), CGRect(x: 400, y: 500, width: 200, height: 28), CGPoint(x: 420, y: 534), .above)),
        NamedCase("shifted in from the screen's right edge", (AnchoredPanel.Placement(edge: .below, alignment: .center, gap: 6), CGRect(x: 950, y: 500, width: 40, height: 28), CGPoint(x: 834, y: 294), .below)),
        NamedCase("beside, trailing", (AnchoredPanel.Placement(edge: .trailing, alignment: .center, gap: 6), CGRect(x: 300, y: 400, width: 20, height: 20), CGPoint(x: 326, y: 310), .trailing)),
        NamedCase("beside, leading without room on the trailing side", (AnchoredPanel.Placement(edge: .trailing, alignment: .center, gap: 6), CGRect(x: 900, y: 400, width: 20, height: 20), CGPoint(x: 734, y: 310), .leading)),
    ])
    func placement(_ testCase: NamedCase<(AnchoredPanel.Placement, CGRect, CGPoint, AnchoredPanel.Edge)>) {
        let (placement, anchor, origin, edge) = testCase.value
        let insets = Metrics.Popover.shadowInsets
        let placed = AnchoredPanel.frame(
            contentSize: CGSize(width: 160 + insets.left + insets.right, height: 200 + insets.top + insets.bottom),
            insets: insets,
            anchor: anchor,
            placement: placement,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placed.edge == edge)
        #expect(CGPoint(x: placed.frame.minX + insets.left, y: placed.frame.minY + insets.bottom) == origin)
    }

    @Test("a popover follows its content's size, its edge by the anchor staying put")
    func followsContentSize() throws {
        let harness = PopoverHarness()
        defer { harness.tearDown() }
        let lines = Lines()
        let controller = harness.show {
            LinesView(lines: lines)
        }
        let before = controller.panel.frame
        lines.count = 6
        controller.host.layoutSubtreeIfNeeded()
        controller.resizeToContent()
        let after = controller.panel.frame
        #expect(after.height > before.height)
        #expect(after.maxY == before.maxY)
        #expect(after.midX == before.midX)
    }

    // MARK: Events

    private func mouseDown(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func escape(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: KeyCode.escape
        ))
    }
}

// MARK: - Views and helpers

/// What the presenting views show.
@MainActor @Observable
private final class PopoverState {
    var isPresented = false
    var tab: ReachabilityTab?
}

/// A view with a popover.
private struct Presenting: View {
    @Bindable var state: PopoverState

    var body: some View {
        Text("Details")
            .frame(width: 80, height: 28)
            .popoverCard(isPresented: $state.isPresented, title: "Details") {
                Text("The details.")
                    .padding(Metrics.Popover.padding)
            }
            .frame(width: 300, height: 200)
    }
}

/// A view with a popover for an item.
private struct PresentingItem: View {
    @Bindable var state: PopoverState

    var body: some View {
        Text("Details")
            .frame(width: 80, height: 28)
            .popoverCard(item: $state.tab) { tab in
                Text(tab.title)
                    .padding(Metrics.Popover.padding)
            }
            .frame(width: 300, height: 200)
    }
}

/// A filter field, as the repository and branch popovers have.
private struct FilterField: View {
    @State private var text = ""

    var body: some View {
        TextField("Filter", text: $text)
            .frame(width: 200)
            .padding(Metrics.Popover.padding)
    }
}

/// How many lines `LinesView` shows.
@MainActor @Observable
private final class Lines {
    var count = 1
}

private struct LinesView: View {
    let lines: Lines

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            ForEach(0..<lines.count, id: \.self) { index in
                Text("Line \(index + 1)")
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(Metrics.Popover.padding)
    }
}

/// Records how a popover takes key focus and moves VoiceOver, and answers
/// what it asks.
@MainActor
private final class FocusRecorder {
    var keyWindow: NSWindow?
    var madeKey: [NSWindow] = []
    var openedByKeyboard = false
    var voiceOver = false
    var accessibilityFocus: [AnyObject] = []

    var focus: PopoverFocus {
        PopoverFocus(
            keyWindow: { [unowned self] in
                self.keyWindow
            },
            makeKey: { [unowned self] window in
                self.madeKey.append(window)
                self.keyWindow = window
            },
            isVoiceOverOn: { [unowned self] in
                self.voiceOver
            },
            openedByKeyboard: { [unowned self] in
                self.openedByKeyboard
            },
            moveAccessibilityFocus: { [unowned self] element in
                self.accessibilityFocus.append(element as AnyObject)
            }
        )
    }
}

/// A window with a view a popover opens from.
@MainActor
private struct PopoverHarness {
    let window: SnapshotWindow
    let anchor: NSView

    init() {
        window = SnapshotWindow(contentRect: CGRect(x: 200, y: 300, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = content
        anchor = NSView(frame: CGRect(x: 160, y: 340, width: 80, height: 28))
        content.addSubview(anchor)
    }

    /// Shows `content` in a popover below the anchor.
    func show<Content: View>(_ recorder: FocusRecorder? = nil, title: String? = nil, @ViewBuilder _ content: @escaping () -> Content) -> PopoverController {
        let controller = PopoverController(title: title, content: content)
        if let recorder {
            controller.focus = recorder.focus
        }
        controller.show(relativeTo: anchor.bounds, of: anchor)
        return controller
    }

    func tearDown() {
        MenuSession.current?.close(animated: false)
        window.contentView = nil
    }
}

// Espalier's tooltips: the rest before one shows and the quicker next one,
// what hides one (the pointer leaving, a click, a key press, a scroll,
// another window, the app deactivating), where the card shows, nil and
// empty text, text changing while one shows, nesting, an AppKit view's
// areas and their owner, SwiftUI's modifier, and an AppKit view's VoiceOver
// help.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Tooltips", .serialized, .hangGuard(minutes: 5)) @MainActor
struct TooltipTests {
    private let fetchFrame = CGRect(x: 20, y: 200, width: 120, height: 30)
    private let pushFrame = CGRect(x: 160, y: 200, width: 120, height: 30)
    private let onFetch = CGPoint(x: 40, y: 210)
    private let onPush = CGPoint(x: 180, y: 210)
    private let away = CGPoint(x: 300, y: 50)

    // MARK: Timing

    @Test("a tooltip shows below the cursor once the pointer has rested on its view 0.8 s, never on screen for an offscreen window; moving on the view starts the rest over")
    func delay() async throws {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let fetch = harness.addView(fetchFrame, tooltip: "Fetch origin")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(799))
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(1))
        #expect(harness.center.shownText == "Fetch origin")
        let shown = try #require(harness.center.shown)
        #expect(shown.anchor == fetch.convert(TooltipCenter.pointerAnchor(at: onFetch, cursorDepth: 20), from: nil))
        #expect(shown.panel.isOpen)
        #expect(!shown.panel.isVisible)

        harness.move(to: away)
        #expect(harness.center.shownText == nil)
        #expect(!shown.panel.isOpen)
        await harness.rest(.seconds(2))

        harness.move(to: onFetch)
        await harness.rest(.milliseconds(500))
        harness.move(to: CGPoint(x: 60, y: 212))
        await harness.rest(.milliseconds(500))
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(300))
        #expect(harness.center.shownText == "Fetch origin")
    }

    @Test("once a tooltip has shown, the next shows after 0.1 s, until none has shown for 1 s")
    func followOn() async {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        harness.addView(fetchFrame, tooltip: "Fetch origin")
        harness.addView(pushFrame, tooltip: "Push origin")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Fetch origin")

        // Straight onto the next view.
        harness.move(to: onPush)
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == "Push origin")

        // Away, and back within the second.
        harness.move(to: away)
        await harness.rest(.milliseconds(500))
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == "Fetch origin")

        // Away for longer: the whole rest again.
        harness.move(to: away)
        await harness.rest(.milliseconds(1_100))
        harness.move(to: onPush)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(700))
        #expect(harness.center.shownText == "Push origin")
    }

    // MARK: Hiding

    @Test("a click or a key press hides the tooltip, which stays hidden on that view until the pointer leaves it; the next view waits the whole rest")
    func clickAndKey() async throws {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        harness.addView(fetchFrame, tooltip: "Fetch origin")
        harness.addView(pushFrame, tooltip: "Push origin")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(800))
        let panel = try #require(harness.center.shown?.panel)
        harness.center.handle(harness.mouse(.leftMouseDown, at: onFetch))
        #expect(harness.center.shownText == nil)
        #expect(!panel.isOpen)
        harness.move(to: CGPoint(x: 50, y: 212))
        #expect(!harness.center.isPending)
        await harness.rest(.seconds(1))
        #expect(harness.center.shownText == nil)

        harness.move(to: onPush)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(700))
        #expect(harness.center.shownText == "Push origin")

        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        harness.center.handle(key)
        #expect(harness.center.shownText == nil)
        harness.move(to: CGPoint(x: 190, y: 211))
        #expect(!harness.center.isPending)

        // Leaving and coming back shows it again.
        harness.move(to: away)
        harness.move(to: onPush)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Push origin")
    }

    @Test("a scroll hides the tooltip, and a view scrolled under the still pointer shows none until the pointer moves")
    func scroll() async throws {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let first = harness.addView(fetchFrame, tooltip: "First commit")
        let second = harness.addView(fetchFrame.offsetBy(dx: 0, dy: -40), tooltip: "Second commit")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "First commit")

        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        harness.center.handle(scroll)
        #expect(harness.center.shownText == nil)
        first.frame = fetchFrame.offsetBy(dx: 0, dy: 40)
        second.frame = fetchFrame
        harness.move(to: onFetch)
        #expect(!harness.center.isPending)
        await harness.rest(.seconds(1))
        #expect(harness.center.shownText == nil)

        harness.move(to: CGPoint(x: onFetch.x + 1, y: onFetch.y))
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Second commit")
    }

    @Test("another window becoming key, or the key window resigning, hides the tooltip, and so does the app deactivating")
    func windowAndApp() async {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        harness.addView(fetchFrame, tooltip: "Fetch origin")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Fetch origin")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
        #expect(harness.center.shownText == nil)

        harness.move(to: CGPoint(x: 50, y: 212))
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Fetch origin")
        // What the app deactivating runs.
        harness.center.hideAll()
        #expect(harness.center.shownText == nil)
        #expect(!harness.center.isPending)
    }

    // MARK: Placement

    @Test("the card shows below the cursor, above the pointer at the screen's bottom, and shifted in from the screen's edge", arguments: [
        NamedCase("below the cursor", (CGPoint(x: 300, y: 400), CGPoint(x: 300, y: 400 - 20 - 4 - 27), AnchoredPanel.Edge.below)),
        NamedCase("above the pointer at the screen's bottom", (CGPoint(x: 300, y: 40), CGPoint(x: 300, y: 44), .above)),
        NamedCase("shifted in from the screen's right edge", (CGPoint(x: 950, y: 400), CGPoint(x: 1000 - 6 - 120, y: 349), .below)),
    ])
    func placement(_ named: NamedCase<(CGPoint, CGPoint, AnchoredPanel.Edge)>) {
        let (pointer, origin, edge) = named.value
        let insets = Metrics.Tooltip.shadowInsets
        let placed = AnchoredPanel.frame(
            contentSize: CGSize(width: 120 + insets.left + insets.right, height: 27 + insets.top + insets.bottom),
            insets: insets,
            anchor: TooltipCenter.pointerAnchor(at: pointer, cursorDepth: 20),
            placement: TooltipCenter.placement,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placed.edge == edge)
        #expect(CGPoint(x: placed.frame.minX + insets.left, y: placed.frame.minY + insets.bottom) == origin)
    }

    // MARK: Text

    @Test("nil or empty text is no tooltip, leaving the pointer to the tooltip around it")
    func noText() async {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let row = harness.addView(CGRect(x: 20, y: 100, width: 300, height: 120), tooltip: "Sources/App/Loader.swift")
        let empty = harness.addView(CGRect(x: 10, y: 10, width: 100, height: 40), tooltip: "", in: row)
        let cleared = harness.addView(CGRect(x: 150, y: 10, width: 100, height: 40), tooltip: "Discard Changes", in: row)
        cleared.setTooltip("")
        #expect(empty.tooltipText == nil)
        #expect(cleared.tooltipText == nil)
        #expect(cleared.accessibilityHelp() == nil)

        harness.move(toMiddleOf: empty)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Sources/App/Loader.swift")
        harness.move(toMiddleOf: cleared)
        #expect(harness.center.shownText == "Sources/App/Loader.swift")
    }

    @Test("a tooltip's text changing while it shows changes in place; gone, the tooltip hides, and back, it shows again")
    func dynamicText() async throws {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let sync = harness.addView(fetchFrame, tooltip: "Fetching origin")
        harness.move(to: onFetch)
        await harness.rest(.milliseconds(800))
        let panel = try #require(harness.center.shown?.panel)
        sync.setTooltip("Fetching origin: Receiving objects 45%")
        #expect(harness.center.shownText == "Fetching origin: Receiving objects 45%")
        #expect(harness.center.shown?.panel === panel)
        #expect(panel.isOpen)

        sync.setTooltip(nil)
        #expect(harness.center.shownText == nil)
        #expect(!panel.isOpen)
        sync.setTooltip("Fetched just now")
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == "Fetched just now")
    }

    @Test("the innermost tooltip under the pointer shows; leaving it for the view around it shows that one's next")
    func nested() async {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let row = harness.addView(CGRect(x: 20, y: 100, width: 300, height: 40), tooltip: "Sources/App/Loader.swift")
        let button = harness.addView(CGRect(x: 260, y: 5, width: 30, height: 30), tooltip: "Discard Changes", in: row)
        harness.move(toMiddleOf: button)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Discard Changes")
        harness.move(to: CGPoint(x: 60, y: 120))
        #expect(harness.center.shownText == nil)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == "Sources/App/Loader.swift")
    }

    // MARK: AppKit areas

    /// A view that names its own tooltip areas, keeping the tags it's asked
    /// for.
    private final class AreaView: NSView, TooltipOwner {
        var asked: [Int] = []

        func tooltip(for view: NSView, tag: Int, at point: CGPoint) -> String? {
            asked.append(tag)
            return tag == 2 ? nil : "Area \(tag)"
        }
    }

    @Test("an AppKit view's areas ask their owner for their text only as they're about to show, and show below the area")
    func areas() async {
        let harness = TooltipHarness()
        defer { harness.tearDown() }
        let view = AreaView(frame: CGRect(x: 20, y: 100, width: 300, height: 100))
        harness.content.addSubview(view)
        let first = CGRect(x: 10, y: 10, width: 20, height: 20)
        view.addTooltipArea(first, owner: view, tag: 1)
        view.addTooltipArea(CGRect(x: 50, y: 10, width: 20, height: 20), owner: view, tag: 2)

        harness.move(to: CGPoint(x: 40, y: 120))
        #expect(view.asked.isEmpty)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Area 1")
        #expect(view.asked == [1])
        #expect(harness.center.shown?.anchor == first)

        // The second area's owner gives none.
        harness.move(to: CGPoint(x: 80, y: 120))
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == nil)
        #expect(view.asked == [1, 2])

        // Outside its areas the view has no tooltip, nor in them once
        // they're removed.
        harness.move(to: CGPoint(x: 200, y: 150))
        #expect(!harness.center.isPending)
        view.removeTooltipAreas()
        harness.move(to: CGPoint(x: 40, y: 120))
        #expect(!harness.center.isPending)
    }

    // MARK: SwiftUI

    @Test("a SwiftUI view's tooltip shows over it; nil and empty show none, leaving the pointer to the tooltip around them")
    func swiftUI() async throws {
        let (window, host) = hostInWindow(
            VStack(spacing: 20) {
                Text("Fetch").frame(width: 120, height: 30).tooltip("Fetch origin")
                Text("None").frame(width: 120, height: 30).tooltip(nil)
                Text("Empty").frame(width: 120, height: 30).tooltip("")
            }
            .padding(20)
            .tooltip("Remote"),
            size: CGSize(width: 240, height: 200)
        )
        let harness = TooltipHarness(window: window)
        defer { harness.tearDown() }
        let regions = allViews(TooltipRegionView.self, in: host)
        #expect(regions.count == 4)
        #expect(regions.compactMap { $0.tooltipText }.sorted() == ["Fetch origin", "Remote"])

        let fetch = try #require(regions.first { $0.tooltipText == "Fetch origin" })
        harness.move(toMiddleOf: fetch)
        await harness.rest(.milliseconds(800))
        #expect(harness.center.shownText == "Fetch origin")

        let none = try #require(regions.first { $0.tooltipText == nil })
        harness.move(toMiddleOf: none)
        await harness.rest(.milliseconds(100))
        #expect(harness.center.shownText == "Remote")
    }

    // MARK: VoiceOver

    @Test("an AppKit view's tooltip is its VoiceOver help")
    func appKitAccessibility() {
        let label = NSTextField(labelWithString: "12m")
        label.setTooltip("Monday, October 5, 2026 at 9:41 AM")
        #expect(label.accessibilityHelp() == "Monday, October 5, 2026 at 9:41 AM")
        label.setTooltip(nil)
        #expect(label.accessibilityHelp() == nil)
    }
}

/// A window whose tooltips a center of the test's shows, on a manual clock,
/// with the pointer moved by hand.
@MainActor
final class TooltipHarness {
    let scheduler = ManualScheduler()
    let center: TooltipCenter
    let window: NSWindow
    /// The trackers the pointer is in.
    private var inside: Set<ObjectIdentifier> = []

    init(window: NSWindow) {
        self.window = window
        center = TooltipCenter(scheduler: scheduler)
        center.cursorDepth = 20
        window.tooltipCenter = center
    }

    /// An empty 400 × 300 window.
    convenience init() {
        let size = CGSize(width: 400, height: 300)
        let window = SnapshotWindow(contentRect: CGRect(origin: CGPoint(x: 200, y: 300), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSView(frame: CGRect(origin: .zero, size: size))
        self.init(window: window)
    }

    var content: NSView {
        window.contentView ?? NSView()
    }

    func tearDown() {
        center.hideAll()
        window.contentView = nil
    }

    /// Adds a view at `frame` in `parent` (the window's content when nil),
    /// with `tooltip`.
    @discardableResult
    func addView(_ frame: CGRect, tooltip: String?, in parent: NSView? = nil) -> NSView {
        let view = NSView(frame: frame)
        view.setTooltip(tooltip)
        (parent ?? content).addSubview(view)
        return view
    }

    /// Moves the pointer to `point` in the window: each view with a tracker
    /// hears it as its tracking area would tell it, entering, moving in, or
    /// leaving the view's visible part.
    func move(to point: CGPoint) {
        let event = mouse(.mouseMoved, at: point)
        for view in allViews(NSView.self, in: content) {
            guard let tracker = view.tooltipTracker else {
                continue
            }
            let id = ObjectIdentifier(tracker)
            if !view.isHiddenOrHasHiddenAncestor, view.convert(view.visibleRect.intersection(view.bounds), to: nil).contains(point) {
                if inside.insert(id).inserted {
                    tracker.mouseEntered(with: event)
                } else {
                    tracker.mouseMoved(with: event)
                }
            } else if inside.remove(id) != nil {
                tracker.mouseExited(with: event)
            }
        }
    }

    /// Moves the pointer to the middle of `view`.
    func move(toMiddleOf view: NSView) {
        let frame = view.convert(view.bounds, to: nil)
        move(to: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Lets the pointer rest for `duration`, from when a waiting tooltip's
    /// rest has started.
    func rest(_ duration: Duration) async {
        if center.isPending {
            await scheduler.waitForSleepers(1)
        }
        await scheduler.advance(by: duration)
    }

    /// A mouse event at `point` in the window.
    func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

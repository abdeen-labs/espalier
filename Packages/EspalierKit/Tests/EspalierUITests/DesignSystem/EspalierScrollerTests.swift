// Espalier's scroller: SwiftUI's ScrollView and List and Espalier's text area
// end up with it once it's installed everywhere; an overlay knob shows after
// a scroll and under the pointer, not at rest, and a hidden one takes no
// clicks; and how it draws, overlay (thin, and thick under the pointer) and
// always shown (on its track), vertical and horizontal.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Espalier's scroller") @MainActor
struct EspalierScrollerTests {
    static let area = "Scroller"

    @Test("SwiftUI's ScrollView and List and the text area get Espalier's scrollers")
    func installedEverywhere() {
        EspalierScroller.installEverywhere()
        let text = FieldText(String(repeating: "A line of text\n", count: 40))
        let view = VStack {
            ScrollView {
                VStack {
                    ForEach(0..<40, id: \.self) { index in
                        Text("Row \(index)")
                    }
                }
            }
            .frame(height: 80)
            List(0..<40, id: \.self) { index in
                Text("Item \(index)")
            }
            .frame(height: 80)
            TextArea(text: text.binding)
                .frame(height: 80)
        }
        .frame(width: 240)
        let (window, host) = hostInWindow(view, size: CGSize(width: 240, height: 300))
        defer { window.contentView = nil }
        let scrollViews = allViews(NSScrollView.self, in: host)
        #expect(scrollViews.count >= 3)
        for scrollView in scrollViews {
            #expect(scrollView.verticalScroller is EspalierScroller, "\(type(of: scrollView))")
            #expect(scrollView.horizontalScroller is EspalierScroller, "\(type(of: scrollView))")
        }
    }

    @Test("an overlay knob shows after a scroll and under the pointer, not at rest; a hidden one takes no clicks")
    func overlayKnob() throws {
        let (window, scrollView) = Self.scrollView(style: .overlay)
        defer { window.contentView = nil }
        let scroller = try #require(scrollView.verticalScroller as? EspalierScroller)
        let point = NSPoint(x: scroller.frame.midX, y: scroller.frame.midY)
        #expect(!scroller.showsKnob)
        #expect(scrollView.hitTest(scrollView.convert(point, to: scrollView.superview)) !== scroller)

        scroller.reveal()
        #expect(scroller.showsKnob)

        scroller.setPointerOver(true)
        #expect(scroller.showsKnob)
        scroller.setPointerOver(false)
        // It lingers before it fades.
        #expect(scroller.showsKnob)
    }

    @Test("a knob always shows while scroll bars are always shown")
    func legacyKnob() throws {
        let (window, scrollView) = Self.scrollView(style: .legacy)
        defer { window.contentView = nil }
        let scroller = try #require(scrollView.verticalScroller as? EspalierScroller)
        #expect(scroller.showsKnob)
    }

    // MARK: Drawing

    enum DrawnState: String, CaseIterable, Sendable {
        case overlayRevealed = "overlay-revealed"
        case overlayHovered = "overlay-hovered"
        case legacy
        case legacyHovered = "legacy-hovered"
        case horizontalRevealed = "horizontal-revealed"
    }

    @Test("draws thin after a scroll, thick under the pointer, and on its track when always shown", arguments: DrawnState.allCases)
    func drawing(_ state: DrawnState) {
        for appearance in SnapshotAppearance.allCases {
            let (window, scrollView) = Self.scrollView(
                style: state == .legacy || state == .legacyHovered ? .legacy : .overlay,
                horizontal: state == .horizontalRevealed,
                appearance: appearance
            )
            let scroller = state == .horizontalRevealed ? scrollView.horizontalScroller : scrollView.verticalScroller
            if let scroller = scroller as? EspalierScroller {
                switch state {
                case .overlayRevealed, .horizontalRevealed:
                    scroller.reveal()
                case .overlayHovered, .legacyHovered:
                    scroller.setPointerOver(true)
                case .legacy:
                    break
                }
            }
            scrollView.layoutSubtreeIfNeeded()
            let image = Snapshot.bitmap(scrollView.bounds.size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            appearance.appearance.performAsCurrentDrawingAppearance {
                Palette.background.setFill()
                scrollView.bounds.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let content = Snapshot.image(of: scrollView)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            content.draw(in: scrollView.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            assertSnapshot(image, named: state.rawValue, area: Self.area, appearance: appearance)
            window.contentView = nil
        }
    }

    /// A scroll view of Espalier's scrollers in an offscreen key window, its
    /// content taller (or wider) than it, scrolled a little way in.
    private static func scrollView(
        style: NSScroller.Style,
        horizontal: Bool = false,
        appearance: SnapshotAppearance = .light
    ) -> (SnapshotWindow, NSScrollView) {
        let size = CGSize(width: 160, height: 120)
        let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = !horizontal
        scrollView.hasHorizontalScroller = horizontal
        scrollView.useEspalierScrollers()
        scrollView.scrollerStyle = style
        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: horizontal ? 600 : size.width, height: horizontal ? size.height : 600))
        window.contentView = scrollView
        scrollView.tile()
        scrollView.contentView.scroll(to: horizontal ? NSPoint(x: 120, y: 0) : NSPoint(x: 0, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        return (window, scrollView)
    }
}

/// A string a binding reads and writes.
@MainActor
private final class FieldText {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }
}

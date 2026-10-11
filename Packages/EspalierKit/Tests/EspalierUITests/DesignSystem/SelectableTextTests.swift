// Selectable text: it takes the size `Text` takes for the same text, font,
// width, line limit, and line spacing; selecting all and copying give plain
// text; a clicked link opens through `openURL`; VoiceOver reads static
// text; text added at the end keeps the selection, other text and another
// view taking focus clear it; and how it draws, selected (in a key window
// and not), with a link, and truncated.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Selectable text") @MainActor
struct SelectableTextTests {
    static let area = "SelectableText"

    nonisolated static let paragraph = "Fetching origin failed because the remote rejected the connection. Check your network and try again, or sign in again if your token has expired."

    /// A text, the width it's offered (nil for none), and how it's limited.
    struct SizeCase: Sendable {
        var text: String
        var width: CGFloat?
        var lineLimit: Int?
        var lineSpacing: CGFloat = 0
        var monospaced = false
    }

    nonisolated static let sizeCases: [NamedCase<SizeCase>] = [
        NamedCase("one short line", SizeCase(text: "main", width: 300)),
        NamedCase("a wrapped paragraph", SizeCase(text: paragraph, width: 220)),
        NamedCase("two lines at most", SizeCase(text: paragraph, width: 220, lineLimit: 2)),
        NamedCase("one line, truncated", SizeCase(text: paragraph, width: 220, lineLimit: 1)),
        NamedCase("lines spaced apart", SizeCase(text: paragraph, width: 220, lineSpacing: 3)),
        NamedCase("SF Mono, offered no width", SizeCase(text: "1a2b3c4 Fix the crash on launch", width: nil, monospaced: true)),
    ]

    @Test("takes the size Text takes", arguments: sizeCases)
    func size(_ testCase: NamedCase<SizeCase>) {
        let value = testCase.value
        let text = Self.measure(Text(value.text).font(value.monospaced ? Typography.sha : Typography.row), value)
        let selectable = Self.measure(SelectableText(value.text, font: value.monospaced ? AppKitTypography.sha : AppKitTypography.row), value)
        #expect(abs(text.width - selectable.width) <= 1, "Text \(text), selectable \(selectable)")
        #expect(abs(text.height - selectable.height) <= 1, "Text \(text), selectable \(selectable)")
    }

    private static func measure(_ view: some View, _ value: SizeCase) -> CGSize {
        let host = NSHostingController(rootView: view.lineLimit(value.lineLimit).lineSpacing(value.lineSpacing))
        return host.sizeThatFits(in: CGSize(width: value.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    // MARK: Behavior

    @Test("selecting all and copying give the plain text, links and all")
    func copy() throws {
        var linked = AttributedString("See ")
        var link = AttributedString("#123")
        link.link = URL(string: "https://github.com/desktop/desktop/issues/123")
        linked += link
        let (window, host) = hostInWindow(SelectableText(linked).frame(width: 200), size: CGSize(width: 200, height: 40))
        defer { window.contentView = nil }
        let textView = try #require(firstView(SelectableTextView.self, in: host))
        #expect(textView.writablePasteboardTypes == [.string])
        textView.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("espalier-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "See #123")
    }

    @Test("a clicked link opens through openURL")
    func link() throws {
        let opened = OpenedURLs()
        let url = try #require(URL(string: "https://github.com/desktop/desktop/pull/1"))
        var text = AttributedString("#1")
        text.link = url
        let view = SelectableText(text)
            .environment(\.openURL, OpenURLAction { url in
                opened.urls.append(url)
                return .handled
            })
        let (window, host) = hostInWindow(view.frame(width: 200), size: CGSize(width: 200, height: 40))
        defer { window.contentView = nil }
        let textView = try #require(firstView(SelectableTextView.self, in: host))
        textView.clicked(onLink: url, at: 0)
        #expect(opened.urls == [url])
    }

    @Test("VoiceOver reads it as static text, or its label when it has one")
    func accessibility() throws {
        let (window, host) = hostInWindow(
            VStack {
                SelectableText("Fix the crash")
                SelectableText("ABCD-1234", accessibilityLabel: "Code: A B C D 1 2 3 4")
            }
            .frame(width: 200),
            size: CGSize(width: 200, height: 60)
        )
        defer { window.contentView = nil }
        let views = allViews(SelectableTextView.self, in: host)
        try #require(views.count == 2)
        #expect(views[0].accessibilityRole() == .staticText)
        #expect(views[0].accessibilityValue() == "Fix the crash")
        #expect(views[1].accessibilityLabel() == "Code: A B C D 1 2 3 4")
        #expect(!views[0].canBecomeKeyView)
    }

    @Test("text added at the end keeps the selection; other text, or another view taking focus, clears it")
    func selectionLifetime() {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let textView = SelectableTextView()
        textView.frame = container.bounds
        container.addSubview(textView)
        window.contentView = container
        defer { window.contentView = nil }

        Self.show("first line", in: textView)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        Self.show("first line\nsecond line", in: textView)
        #expect(textView.string == "first line\nsecond line")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

        Self.show("other text", in: textView)
        #expect(textView.selectedRange().length == 0)

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(window.makeFirstResponder(nil))
        #expect(textView.selectedRange().length == 0)
    }

    private static func show(_ text: String, in textView: SelectableTextView) {
        let content = SelectableTextContent(
            string: SelectableTextContent.attributedString(
                AttributedString(text), font: AppKitTypography.sha, color: Palette.text, kerning: 0, paragraphStyle: NSParagraphStyle.default
            ),
            lineLimit: nil,
            truncation: .byTruncatingTail,
            lineSpacing: 0,
            accessibilityLabel: nil
        )
        textView.show(content, layout: SelectableTextLayout(content))
    }

    // MARK: Drawing

    @Test("draws as Text draws: plain, selected with focus and without, a link, and truncated")
    func drawing() {
        for appearance in SnapshotAppearance.allCases {
            assertSnapshot(Self.render(appearance: appearance, selection: nil, isKey: true), named: "plain", area: Self.area, appearance: appearance)
            assertSnapshot(Self.render(appearance: appearance, selection: NSRange(location: 9, length: 20), isKey: true), named: "selected-focused", area: Self.area, appearance: appearance)
            assertSnapshot(Self.render(appearance: appearance, selection: NSRange(location: 9, length: 20), isKey: false), named: "selected-unfocused", area: Self.area, appearance: appearance)
        }
    }

    /// A paragraph, a line with a link and bold, and a truncated path, with
    /// `selection` in the paragraph, in a window that's key or not.
    private static func render(appearance: SnapshotAppearance, selection: NSRange?, isKey: Bool) -> NSBitmapImageRep {
        let size = CGSize(width: 260, height: 100)
        var linked = AttributedString("Closes ")
        var link = AttributedString("#123")
        link.link = URL(string: "https://github.com/desktop/desktop/issues/123")
        linked += link
        linked += AttributedString(" and ")
        linked += (try? AttributedString(markdown: "**keeps** the rest")) ?? AttributedString("keeps the rest")
        let view = VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            SelectableText("Fetching origin failed because the remote rejected the connection.", color: Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            SelectableText(linked, font: AppKitTypography.secondary)
            SelectableText("/Users/maya/Developer/espalier/Packages/EspalierKit/Sources", font: AppKitTypography.sha, color: Palette.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(Metrics.insetSmall)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        let window = KeyStateWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.reportsKey = isKey
        window.appearance = appearance.appearance
        let host = NSHostingView(rootView: Snapshot.deterministic(view).background(Color(nsColor: Palette.background)))
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let selection, let textView = firstView(SelectableTextView.self, in: host) {
            window.makeFirstResponder(textView)
            textView.setSelectedRange(selection)
        }
        host.layoutSubtreeIfNeeded()
        return Snapshot.image(of: host)
    }
}

/// A window that draws in sRGB and is key, or not, as a test says.
private final class KeyStateWindow: NSWindow {
    var reportsKey = true

    override var isKeyWindow: Bool { reportsKey }
    override var isMainWindow: Bool { reportsKey }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        colorSpace = .sRGB
    }
}

/// The URLs an `openURL` action was given.
@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

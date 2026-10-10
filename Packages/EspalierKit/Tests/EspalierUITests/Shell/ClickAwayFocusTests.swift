// A click away from a text field ends its editing: the commit message's
// summary and description, and a capsule search field. A click in the
// field, or in the area around it that belongs to it, leaves it focused.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Click away from a field") @MainActor
struct ClickAwayFocusTests {
    @Test("a click away from the summary or the description ends its editing; a click in it, or in its part of the card, doesn't")
    func composer() throws {
        let content = ComposerContent(author: ChangesFixtures.author, sparkle: .ready(model: "GPT-5"), button: ChangesFixtures.button(enabled: false))
        let (window, host) = hostInWindow(
            ChangesFixtures.composer(content),
            size: CGSize(width: Metrics.Column.changesFileList.ideal + 40, height: 400)
        )
        defer { window.contentView = nil }
        let summary = try #require(firstView(SummaryNSTextField.self, in: host))
        let description = try #require(firstView(ComposerTextView.self, in: host))
        let descriptionScrollView = try #require(description.enclosingScrollView)
        let fields: [(focus: NSView, edited: NSView)] = [(summary, summary), (description, descriptionScrollView)]
        for field in fields {
            let frame = field.edited.convert(field.edited.bounds, to: nil)
            let clicks: [(point: CGPoint, keepsFocus: Bool)] = [
                (CGPoint(x: frame.midX, y: frame.midY), true),
                // The card's padding beside the field, in its part of the
                // card.
                (CGPoint(x: frame.minX - 4, y: frame.midY), true),
                // Beside the composer.
                (CGPoint(x: 2, y: 2), false),
            ]
            for click in clicks {
                window.makeFirstResponder(nil)
                #expect(window.makeFirstResponder(field.focus))
                #expect(ClickAwayFocus.editedView(window.firstResponder) === field.edited)
                ClickAwayFocus.endEditing(forClickAt: click.point, in: window)
                #expect((ClickAwayFocus.editedView(window.firstResponder) === field.edited) == click.keepsFocus)
            }
        }
    }

    @Test("a click on a search field's symbol or clear button leaves it focused; a click away ends its editing")
    func searchField() throws {
        let (window, host) = hostInWindow(
            CapsuleSearchField("Filter Changed Files", text: .constant("README")).padding(20),
            size: CGSize(width: 280, height: 70)
        )
        defer { window.contentView = nil }
        let field = try #require(firstView(NSTextField.self, in: host))
        let frame = field.convert(field.bounds, to: nil)
        let clicks: [(point: CGPoint, keepsFocus: Bool)] = [
            (CGPoint(x: frame.minX - 14, y: frame.midY), true),
            (CGPoint(x: frame.maxX + 14, y: frame.midY), true),
            (CGPoint(x: 2, y: 2), false),
        ]
        for click in clicks {
            window.makeFirstResponder(nil)
            #expect(window.makeFirstResponder(field))
            #expect(ClickAwayFocus.editedView(window.firstResponder) === field)
            ClickAwayFocus.endEditing(forClickAt: click.point, in: window)
            #expect((ClickAwayFocus.editedView(window.firstResponder) === field) == click.keepsFocus)
        }
    }
}

// A click on the Changes header's title reaches its checkbox, as a click
// on a checkbox's own title does: the title drawn over the checkbox, so its
// count can roll, takes no clicks.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Changes header's title") @MainActor
struct ChangesHeaderTitleTests {
    @Test("a click on the title goes to the checkbox, which includes every file")
    func clickOnTitle() throws {
        var included: [Bool] = []
        let content = ChangesHeaderContent(
            title: "7 changed files",
            included: "3 included",
            includeAll: nil,
            isIncludeAllEnabled: true,
            filter: FilterMenuContent(),
            fileCount: 7
        )
        let hosting = NSHostingView(rootView: ChangesHeader(content, onIncludeAll: { included.append($0) }).frame(width: 320))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
        }
        let checkbox = try #require(Self.descendants(of: hosting).compactMap { $0 as? CheckboxButton }.first)
        #expect(!checkbox.drawsTitle)

        // A point on the title's first character, where the header draws it.
        let titleHeight = NSAttributedString(string: content.title, attributes: [.font: ChangesHeader.titleFont]).size().height
        let title = CheckboxButton.titleRect(height: titleHeight, in: checkbox.bounds.size)
        let point = checkbox.convert(CGPoint(x: title.minX + 4, y: title.midY), to: hosting.superview)
        let hit = try #require(hosting.hitTest(point))
        #expect(hit === checkbox)

        // AppKit sends the click to what the hit lands on.
        checkbox.performClick(nil)
        #expect(included == [true])
    }

    /// Every view under `view`.
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

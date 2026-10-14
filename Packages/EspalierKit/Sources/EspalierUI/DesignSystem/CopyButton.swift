// A button that copies text and says so: a copy gives no other feedback, so
// its symbol turns into a check for 1.5 s (a symbol replace; at once with
// Reduce Motion), then back.

import AppKit
import SwiftUI

/// Copies `text` to the pasteboard; its symbol (`doc.on.doc`) shows a
/// check for 1.5 s after each copy.
public struct CopyButton<Label: View>: View {
    private let text: String
    private let copy: ((String) -> Void)?
    private let label: (_ systemImage: String) -> Label
    @State private var showsCheck = false
    /// Copies made, so each one restarts the check's time.
    @State private var copies = 0
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - text: What a click copies.
    ///   - copy: Copies the text; the general pasteboard by default.
    ///   - label: The button's look for a symbol name: `doc.on.doc`, or
    ///     `checkmark` after a copy.
    public init(
        _ text: String,
        copy: ((String) -> Void)? = nil,
        @ViewBuilder label: @escaping (_ systemImage: String) -> Label
    ) {
        self.text = text
        self.copy = copy
        self.label = label
    }

    /// Puts `text` on the general pasteboard.
    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public var body: some View {
        Button {
            if let copy {
                copy(text)
            } else {
                Self.copyToPasteboard(text)
            }
            withMotion(motion, Motion.leave) {
                showsCheck = true
            }
            copies += 1
        } label: {
            label(showsCheck ? "checkmark" : "doc.on.doc")
                // A symbol replace plays whatever the transaction says.
                .contentTransition(motion.animates ? .symbolEffect(.replace) : .identity)
        }
        .task(id: copies) {
            guard copies > 0 else {
                return
            }
            try? await Task.sleep(for: Motion.copiedCheck)
            guard !Task.isCancelled else {
                return
            }
            withMotion(motion, Motion.leave) {
                showsCheck = false
            }
        }
    }
}

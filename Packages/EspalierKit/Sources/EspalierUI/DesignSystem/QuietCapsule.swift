// A small capsule of quiet text on the field fill, as tall as a ref tag: a
// word that marks a row or a title ("Draft", "Local", "Archived") in the
// sans, or a branch name in the mono, as the ref tags draw names.

import SwiftUI

/// A small capsule of quiet text: a word in the sans, or a branch name in
/// the mono.
struct QuietCapsule: View {
    private let text: String
    private let monospaced: Bool

    /// - Parameter monospaced: Whether `text` is a name (a branch), in the
    ///   ref tags' mono; else a word, in the sans.
    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    var body: some View {
        Text(text)
            .font(monospaced ? Typography.refCapsule : Typography.capsuleWord)
            .foregroundStyle(.text2)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
            .frame(height: Metrics.RefCapsule.height)
            .background(Capsule(style: .circular).fill(Color(espalier: Palette.field)))
            .tooltip(text)
    }
}

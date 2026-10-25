// A small capsule of quiet text on the field fill, in the ref tags' mono
// and height: a word that marks a row or a title ("Draft", "Local",
// "Archived"), or a branch name, with the whole name in its tooltip.

import SwiftUI

/// A small capsule of quiet text: a word, or a branch name.
struct QuietCapsule: View {
    private let text: String
    private let isName: Bool

    /// - Parameter isName: Whether `text` is a name (a branch), which a
    ///   narrow capsule cuts, with the whole name in its tooltip.
    init(_ text: String, isName: Bool = false) {
        self.text = text
        self.isName = isName
    }

    var body: some View {
        Text(text)
            .font(Typography.refCapsule)
            .foregroundStyle(.text2)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
            .frame(height: Metrics.RefCapsule.height)
            .background(Capsule(style: .circular).fill(Color(espalier: Palette.field)))
            .tooltip(isName ? text : nil)
    }
}

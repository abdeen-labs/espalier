// The line attributes of a run in Espalier's rich text, which sets SwiftUI's
// (`RichText`, `MarkdownDocument`). This file imports SwiftUI without AppKit,
// whose attribute scope has lines of the same names.

import Foundation
import SwiftUI

extension AttributedString.Runs.Run {
    /// Whether the run is underlined (a link, with "Underline links" on).
    var isUnderlined: Bool {
        self[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] != nil
    }

    /// Whether the run is struck through.
    var isStruckThrough: Bool {
        self[AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self] != nil
    }
}

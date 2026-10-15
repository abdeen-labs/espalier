// Counts as the interface shows them, in the user's number format
// (Settings ▸ Appearance's Number format): "1,204" or "1.204". A window's
// views read the format from the environment (`numberFormat`), which the
// window sets from the settings; AppKit lists take it from the view that
// hosts them and carry it in their rows' content.

import GitKit
import SwiftUI

/// `count` with `format`'s grouping separator ("1,204").
nonisolated func formatCount(_ count: Int, _ format: NumberFormat) -> String {
    formatNumber(Double(count), format)
}

extension EnvironmentValues {
    /// How numbers show; the window sets it from the settings.
    @Entry public var numberFormat: NumberFormat = defaultNumberFormat
}

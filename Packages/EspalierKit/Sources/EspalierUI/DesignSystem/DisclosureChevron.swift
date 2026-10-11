// Espalier's disclosure chevron: right while closed, down while open,
// turning between them over 0.15 s. The sidebar's branch folders and groups
// draw it before their label.

import SwiftUI

/// A chevron that turns down as what it discloses opens.
public struct DisclosureChevron: View {
    private let isExpanded: Bool

    public init(isExpanded: Bool) {
        self.isExpanded = isExpanded
    }

    public var body: some View {
        // The sidebar sections' chevron's size and weight.
        Image(systemName: "chevron.right")
            .font(Typography.row.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(.text3)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .motion(Motion.leave, value: isExpanded)
            .accessibilityHidden(true)
    }
}

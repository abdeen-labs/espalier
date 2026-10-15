// A pull-down menu drawn as a capsule button: a `PullDownButton` with a
// capsule button style and this label, the title and a small chevron. Its
// menu is Espalier's card. Pop-ups, which show a choice, are
// `CapsulePopUp`s.

import SwiftUI

/// A capsule menu's label: the title, then a small down chevron in the
/// symbol color.
public struct MenuCapsuleLabel: View {
    private let title: String
    private let systemImage: String?

    /// - Parameter systemImage: A symbol before the title.
    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Metrics.CapsuleMenu.chevronSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .semibold))
                .opacity(0.6)
                .accessibilityHidden(true)
        }
    }
}

extension Metrics {
    /// Menus drawn as capsules.
    public enum CapsuleMenu {
        public static let chevronSize: CGFloat = 9
        public static let chevronSpacing: CGFloat = 6
    }
}

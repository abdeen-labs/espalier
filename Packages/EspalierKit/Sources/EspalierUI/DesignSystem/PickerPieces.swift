// The pieces the location control's popovers and the command palette share:
// a header (a bold title and what trails it) and an empty state (a plain
// symbol, a bold title, a sentence, and the action that helps).

import SwiftUI

/// A popover's header: its title in bold, and what trails it (New Branch…,
/// the Add menu).
struct PickerHeader<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Text(title)
                .font(Typography.paneHeading)
                .foregroundStyle(.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Metrics.insetSmall)
            accessory
        }
        .frame(height: Metrics.Pickers.headerHeight)
    }
}

/// An empty list in a popover: a plain symbol, a bold title, a sentence,
/// and the action that helps.
struct PickerEmptyState<Actions: View>: View {
    private let title: String
    private let message: String?
    private let systemImage: String
    private let actions: Actions

    init(_ title: String, message: String? = nil, systemImage: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Metrics.insetSmall) {
            Image(systemName: systemImage)
                .font(.system(size: Metrics.Pickers.emptySymbol))
                .foregroundStyle(.text3)
                .padding(.bottom, Metrics.grid)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.display(size: 16))
                .foregroundStyle(.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, Metrics.grid)
        }
        .frame(maxWidth: Metrics.Pickers.emptyWidth)
        .padding(Metrics.insetLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension Metrics {
    /// The location control's popovers and the command palette.
    public enum Pickers {
        /// A popover's header.
        public static let headerHeight: CGFloat = 30
        /// A row, roomier than a sheet's list.
        public static let rowHeight: CGFloat = 34
        /// An empty state's symbol's point size, and its text's widest.
        public static let emptySymbol: CGFloat = 32
        public static let emptyWidth: CGFloat = 280
    }
}

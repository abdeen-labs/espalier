// The pieces every Settings pane is made of: the page, which scrolls under
// the pane's header; sections in the theme's look, as cards on the
// backdrop, each under its bold title, or split by hairlines, each under a
// section label; rows split by hairlines, each with its title and an
// optional description on the left and its control on the right; rows for
// a message or for buttons alone;
// the "Local" badge; a row's "⋯" menu; and the fade of what a change shows
// or hides. Messages under a control are `FieldMessage`s, as in sheets.

import EspalierCore
import SwiftUI

// MARK: - Page and sections

/// A pane's content: its sections, inset from the pane's edges, scrolling
/// when the pane is taller than the window, never past its ends. In the
/// theme's look (`SettingsThemeStyle.Groups`): cards spaced apart, or
/// sections split by hairlines.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let isCards = Theme.current.style.settings.groups == .cards
        ScrollView {
            Group {
                if isCards {
                    VStack(alignment: .leading, spacing: Metrics.SettingsCards.sectionSpacing) {
                        content
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Group(subviews: content) { sections in
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                if index > 0 {
                                    Hairline()
                                }
                                section
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, isCards ? Metrics.SettingsCards.pageInset : Metrics.SettingsWindow.contentInset)
            .padding(.top, Metrics.SettingsWindow.contentTopInset)
            .padding(.bottom, isCards ? Metrics.SettingsCards.pageInset : Metrics.SettingsWindow.contentBottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .unbouncedScrollContent(fadesEdges: true)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A section, in the theme's look: its bold title, then its rows in a card,
/// split by hairlines; or its section label, then its rows, split by
/// hairlines.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content

    /// - Parameter title: The title; nil for a section that needs none (a
    ///   pane's one main switch).
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if Theme.current.style.settings.groups == .cards {
            card
        } else {
            plain
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Metrics.SettingsCards.labelSpacing) {
            if let title {
                Text(title)
                    .font(Typography.settingsSectionTitle)
                    .foregroundStyle(.text2)
                    .padding(.leading, Metrics.SettingsCards.labelInset)
                    .accessibilityAddTraits(.isHeader)
            }
            rows
                .padding(.horizontal, Metrics.SettingsCards.rowInset)
                .padding(.vertical, Metrics.SettingsCards.cardVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Color(espalier: Palette.background), elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionLabel(title)
                    .padding(.top, Metrics.SettingsWindow.sectionLabelTop)
                    .padding(.bottom, Metrics.SettingsWindow.sectionLabelBottom)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Color.clear
                    .frame(height: Metrics.SettingsWindow.untitledSectionTop)
                    .accessibilityHidden(true)
            }
            rows
        }
    }

    /// The rows, split by hairlines.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Hairline()
                    }
                    row
                }
            }
        }
    }
}

extension Metrics {
    /// Settings' groups as cards on the backdrop.
    public enum SettingsCards {
        /// Around the page's cards.
        public static let pageInset: CGFloat = 24
        /// Between one group and the next.
        public static let sectionSpacing: CGFloat = 22
        /// Between a group's title and its card, and the title's inset
        /// from the card's edge.
        public static let labelSpacing: CGFloat = 8
        public static let labelInset: CGFloat = 4
        /// Inside a card: beside its rows, and above the first and below
        /// the last.
        public static let rowInset: CGFloat = 16
        public static let cardVerticalInset: CGFloat = 4
        /// The window's width, and its sidebar's: the theme's.
        public static var windowWidth: CGFloat { Theme.current.style.settings.windowWidth }
        public static var sidebarWidth: CGFloat { Theme.current.style.settings.sidebarWidth }
        /// The sidebar's tiled rows: their height, and their tiles.
        public static let sidebarRowHeight: CGFloat = 34
        public static let sidebarTile: CGFloat = 22
    }
}

extension Metrics.SettingsWindow {
    /// Settings' groups split by hairlines: the pane's content and header
    /// inset from its sides, and the space below its last section.
    public static let contentInset: CGFloat = 20
    public static let contentBottomInset: CGFloat = 20
    /// Space above a section label.
    public static let sectionLabelTop: CGFloat = 18
    /// Space above a section without a label.
    public static let untitledSectionTop: CGFloat = 8
}

extension Typography {
    /// A Settings group's title over its card (13, bold, as written).
    static var settingsSectionTitle: Font { sans(.body, weight: .bold) }
    /// A Settings pane's name in its header, in the theme's look: display
    /// type, 22 bold, or the headline (13, bold).
    static var settingsPaneTitle: Font {
        switch Theme.current.style.settings.paneTitle {
        case .display: display(size: 22)
        case .headline: paneTitle
        }
    }
}

// MARK: - Rows

/// A row: the title (13 medium) and an optional description (12, tertiary
/// text) on the left, the control on the right, and an optional message
/// under them.
struct SettingsRow<Control: View, Footer: View>: View {
    private let title: String
    private let description: String?
    private let labelsControl: Bool
    private let control: Control
    private let footer: Footer

    /// - Parameters:
    ///   - labelsControl: Whether the control is labeled with the title (a
    ///     switch, a field, a pop-up): VoiceOver then reads the title once,
    ///     as the control's label, and the description as its hint.
    init(
        _ title: String,
        description: String? = nil,
        labelsControl: Bool = false,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.description = description
        self.labelsControl = labelsControl
        self.control = control()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.SettingsWindow.messageSpacing) {
            HStack(spacing: Metrics.SettingsWindow.rowSpacing) {
                SettingsRowText(title: title, description: description)
                    .accessibilityHidden(labelsControl)
                if labelsControl, let description {
                    control
                        .accessibilityHint(Text(description))
                } else {
                    control
                }
            }
            footer
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
    }
}

/// A row's title and description.
struct SettingsRowText: View {
    let title: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.SettingsWindow.descriptionSpacing) {
            Text(title)
                .font(Typography.rowTitle)
                .foregroundStyle(.text)
                .fixedSize(horizontal: false, vertical: true)
            if let description {
                Text(description)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row with a switch: the title, an optional description, and Espalier's
/// switch, which VoiceOver reads with the title and the description.
struct SettingsToggleRow: View {
    private let title: String
    private let description: String?
    @Binding private var isOn: Bool

    init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, description: description, labelsControl: true) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.capsuleSwitch)
                .labelsHidden()
        }
    }
}

/// A row that says something (a note, a problem, a status), with buttons
/// on the right when there are any.
struct SettingsMessageRow<Message: View, Trailing: View>: View {
    private let message: Message
    private let trailing: Trailing

    init(@ViewBuilder message: () -> Message, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.message = message()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Metrics.SettingsWindow.rowSpacing) {
            message
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
    }
}

/// A row of buttons alone, on the right (Add Provider…).
struct SettingsButtonRow<Buttons: View>: View {
    private let buttons: Buttons

    init(@ViewBuilder buttons: () -> Buttons) {
        self.buttons = buttons()
    }

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
    }
}

/// A note in a row: 12, tertiary text.
struct SettingsNote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Typography.secondary)
            .foregroundStyle(.text3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Badges and menus

/// The "Local" badge: a provider whose server is this Mac.
struct LocalBadge: View {
    var body: some View {
        QuietCapsule("Local")
            .accessibilityLabel("Local server")
    }
}

/// A row's trailing "⋯" menu.
struct RowActionsMenu: View {
    private let label: String
    private let content: () -> MenuContent

    /// - Parameter label: What VoiceOver reads ("Actions for OpenAI").
    init(_ label: String, @MenuBuilder content: @escaping () -> MenuContent) {
        self.label = label
        self.content = content
    }

    var body: some View {
        PullDownButton(label, menu: content) {
            Label(label, systemImage: "ellipsis.circle")
        }
        .buttonStyle(.icon)
        .fixedSize()
        .tooltip(label)
    }
}

/// A pane that can't show yet (no app model or window context).
struct SettingsPanePlaceholder: View {
    let tab: SettingsTab

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsMessageRow {
                    SettingsNote("Not available yet.")
                }
            }
        }
    }
}

extension View {
    /// A button in a Settings row: a small quiet capsule.
    func settingsButton() -> some View {
        buttonStyle(.quiet)
            .controlSize(.small)
    }

    /// A field or pop-up in a Settings row: a capsule at the rows' control
    /// width.
    func settingsControlWidth(_ width: CGFloat = Metrics.SettingsWindow.controlWidth) -> some View {
        frame(width: width)
    }

    /// A pop-up in a Settings row whose choices can be wider than the rows'
    /// control width (`CapsulePopUp(fitting:)`): at that width, or at its
    /// ideal width when that's wider, so the chosen title shows whole.
    func settingsControlWidthFittingChoices() -> some View {
        AtLeastIdealWidth(minimum: Metrics.SettingsWindow.controlWidth) {
            self
        }
    }

    /// A row, message, or section that a change brings or takes away: it
    /// fades with the motion of that change (a choice made with
    /// `withMotion`, a list keyed with `motion(_:value:)`) and has none of
    /// its own, unlike `barTransition()`, so what a load shows appears at
    /// once. No transition where motion doesn't run.
    func settingsTransition() -> some View {
        modifier(SettingsTransition())
    }
}

/// `settingsTransition()`: a fade, where motion runs.
private struct SettingsTransition: ViewModifier {
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.transition(motion.animates ? .opacity : .identity)
    }
}

/// Its view at its ideal width rounded up to a whole point, but at least
/// `minimum`, offered that width so a view that fills its width fills it.
private struct AtLeastIdealWidth: Layout {
    let minimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else {
            return .zero
        }
        let width = max(minimum, content.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width.rounded(.up))
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

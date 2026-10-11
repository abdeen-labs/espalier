// The pieces every Settings pane is made of: the page, which scrolls under
// the pane's header; sections with an uppercase label; flat rows split by
// hairlines, each with its title and an optional description on the left
// and its control on the right; rows for a message or for buttons alone;
// the "Local" badge; and a row's "⋯" menu. Messages under a control are
// `FieldMessage`s, as in sheets.

import EspalierCore
import SwiftUI

// MARK: - Page and sections

/// A pane's content: its sections, split by hairlines, inset from the
/// pane's edges, scrolling when the pane is taller than the window.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
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
            .padding(.horizontal, Metrics.SettingsWindow.contentInset)
            .padding(.top, Metrics.SettingsWindow.contentTopInset)
            .padding(.bottom, Metrics.SettingsWindow.contentBottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A section: its uppercase label (as the main window's sidebar labels
/// its sections), then its rows, split by hairlines.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content

    /// - Parameter title: The label; nil for a section that needs none (a
    ///   pane's one main switch).
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionLabel(title)
                    .padding(.top, Metrics.SettingsWindow.sectionLabelTop)
                    .padding(.bottom, Metrics.SettingsWindow.sectionLabelBottom)
            } else {
                Color.clear
                    .frame(height: Metrics.SettingsWindow.untitledSectionTop)
                    .accessibilityHidden(true)
            }
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
        Text("Local")
            .font(Typography.refCapsule)
            .foregroundStyle(.text2)
            .padding(.horizontal, Metrics.RefCapsule.horizontalPadding)
            .frame(height: Metrics.RefCapsule.height)
            .background(Capsule(style: .circular).fill(Color(espalier: Palette.field)))
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
}

extension AppModel {
    /// Opens a System Settings pane (`x-apple.systempreferences:` URLs),
    /// through the integrations' browser opener, which tests record.
    func openSystemSettings(_ url: String) {
        if let url = URL(string: url) {
            integrations.openInBrowser(url)
        }
    }
}

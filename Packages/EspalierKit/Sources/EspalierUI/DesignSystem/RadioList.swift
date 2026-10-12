// A choice between longer options as flat rows: a radio mark and the title,
// the rows split by hairlines, the chosen title semibold. `ChoiceList`'s
// rows are cards, for sheets' choices that each have a line about them;
// these sit in a pane's list of rows, and in a form's column for plain
// choices (Repository Settings' Git config, Configure Git's author). It's
// one stop in the key view loop, with the focus ring around the chosen
// row's mark; the up and down arrows move the choice, and VoiceOver sees a
// radio group whose buttons have the lines under the titles as their hints.

import SwiftUI

/// Choices as flat rows: a radio mark, the title, and an optional line
/// under it; hairlines between the rows.
public struct RadioList<Value: Hashable>: View {
    private let label: String
    private let choices: [ChoiceListItem<Value>]
    @Binding private var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    /// - Parameter label: What VoiceOver calls the group.
    public init(_ label: String, selection: Binding<Value>, choices: [ChoiceListItem<Value>]) {
        self.label = label
        _selection = selection
        self.choices = choices
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Hairline()
                }
                row(choice)
            }
        }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        // Focus only with keyboard navigation on.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            move(by: -1)
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(choices) { choice in
                    Text(choice.title)
                        .accessibilityHint(choice.accessibilityHint)
                        .tag(choice.value)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func row(_ choice: ChoiceListItem<Value>) -> some View {
        let isSelected = choice.value == selection
        let markOffset = Metrics.RadioList.markBaselineOffset
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.RadioList.markSpacing) {
            RadioMark(isSelected: isSelected)
                .focusRing(isFocused && isSelected, in: Circle())
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    // The mark's center on the title's middle.
                    dimensions[VerticalAlignment.center] + markOffset
                }
            VStack(alignment: .leading, spacing: Metrics.RadioList.descriptionSpacing) {
                Text(choice.title)
                    .font(isSelected ? Typography.row.weight(.semibold) : Typography.row)
                    .foregroundStyle(.text)
                if let description = choice.description {
                    Text(description)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Metrics.RadioList.verticalPadding)
        .frame(minHeight: Metrics.RadioList.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEnabled {
                selection = choice.value
            }
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard isEnabled, let index = choices.firstIndex(where: { $0.value == selection }) else {
            return .ignored
        }
        let next = index + offset
        guard choices.indices.contains(next) else {
            return .handled
        }
        selection = choices[next].value
        return .handled
    }
}

extension Metrics {
    /// A `RadioList`'s rows.
    public enum RadioList {
        /// A row is at least this high: 40 with the hairline under it.
        public static let rowHeight: CGFloat = 39
        /// The space above and below a row's text.
        public static let verticalPadding: CGFloat = 9
        /// Between the radio mark and the title.
        public static let markSpacing: CGFloat = 11
        /// Between the title and the line under it.
        public static let descriptionSpacing: CGFloat = 2
        /// Lowers the mark's center onto the middle of the title's first
        /// line (body text's x-height middle sits about 4 above the
        /// baseline), here, in a `ChoiceList`, and beside a checkbox
        /// toggle's label.
        public static let markBaselineOffset: CGFloat = 4
    }
}

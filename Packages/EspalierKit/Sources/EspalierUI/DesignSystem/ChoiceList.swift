// A choice between a few options, each with a line about it: rows with
// radius 11, the chosen one in `accent soft` with a filled radio mark.
// Sheets use it where a radio group would list choices with descriptions
// (Switch Branch's decision, New Branch's base). The up and down arrows move
// the choice, and VoiceOver sees a native radio group.

import AppKit
import SwiftUI

/// One choice in a `ChoiceList`.
public struct ChoiceListItem<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public let description: AttributedString?

    /// - Parameter description: The line under the title, as it is (no
    ///   Markdown).
    public init(_ title: String, description: String? = nil, value: Value) {
        self.title = title
        self.description = description.map { AttributedString($0) }
        self.value = value
    }

    /// - Parameter description: The line under the title, styled (bold
    ///   names).
    public init(_ title: String, styledDescription: AttributedString, value: Value) {
        self.title = title
        description = styledDescription
        self.value = value
    }

    public var id: Value { value }
}

/// Choices as rows: a radio mark, the title, and the line under it; the
/// chosen row tinted with the accent.
public struct ChoiceList<Value: Hashable>: View {
    private let label: String
    private let choices: [ChoiceListItem<Value>]
    @Binding private var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter label: What VoiceOver calls the group.
    public init(_ label: String, selection: Binding<Value>, choices: [ChoiceListItem<Value>]) {
        self.label = label
        _selection = selection
        self.choices = choices
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.ChoiceList.spacing) {
            ForEach(choices) { choice in
                let isSelected = choice.value == selection
                HStack(alignment: .top, spacing: Metrics.ChoiceList.markSpacing) {
                    RadioMark(isSelected: isSelected)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                            .font(Typography.row.weight(.medium))
                            .foregroundStyle(.text)
                        if let description = choice.description {
                            Text(description)
                                .font(Typography.secondary)
                                .foregroundStyle(.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.ChoiceList.horizontalPadding)
                .padding(.vertical, Metrics.ChoiceList.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(.line), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous))
                .onTapGesture {
                    if isEnabled {
                        selection = choice.value
                    }
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        // Focus only with keyboard navigation on, as native radio buttons,
        // with a ring in the rows' shape.
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous))
        .focusable(interactions: .activate)
        .onKeyPress(.upArrow) {
            move(by: -1)
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice.value)
                }
            }
            .pickerStyle(.radioGroup)
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

/// A radio mark: 15 points; the accent with a white dot when chosen, else
/// a `line2` ring on the quiet fill.
public struct RadioMark: View {
    private let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public var body: some View {
        ZStack {
            // As a native radio button's: the fill crossfades and the dot
            // fades and scales in over 0.15 s.
            Circle()
                .fill(isSelected ? Color.accentColor : Color.quiet)
            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: Metrics.ChoiceList.dotSize, height: Metrics.ChoiceList.dotSize)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(.line2, lineWidth: 1)
                    .transition(.opacity)
            }
        }
        .motion(Motion.leave, value: isSelected)
        .frame(width: Metrics.Checkbox.size, height: Metrics.Checkbox.size)
        .accessibilityHidden(true)
    }
}

extension Metrics {
    /// A `ChoiceList`'s rows.
    public enum ChoiceList {
        public static let spacing: CGFloat = 6
        public static let horizontalPadding: CGFloat = 12
        public static let verticalPadding: CGFloat = 9
        /// Between the radio mark and the title.
        public static let markSpacing: CGFloat = 10
        /// The dot inside a chosen radio mark.
        public static let dotSize: CGFloat = 6
    }
}

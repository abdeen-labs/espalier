// Settings ▸ Appearance's theme, palette, and background pickers, Espalier's
// own controls. The theme is four cards, each a small preview of its theme
// in the chosen palette and background (the sidebar with its selection, a
// selected row, the prominent capsule) with the theme's name under it; the
// chosen card has the focus-ring-style accent ring. The palettes and the
// background tints are round swatches, the chosen one ringed. Each picker is
// one stop in the key view loop: the left and right arrows move the choice,
// and VoiceOver sees a radio group.

import EspalierCore
import SwiftUI

extension DesignTheme {
    /// The theme's name in Settings.
    var title: String {
        switch self {
        case .classic: "Classic"
        case .frost: "Frost"
        case .islands: "Islands"
        case .pop: "Pop"
        }
    }
}

extension DesignPalette {
    /// The palette's name in Settings.
    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// What Settings says of the palette under its row's title: its name
    /// and the theme it's made for, and for System, whose color it is.
    var summary: String {
        self == .system ? "Your Mac's accent color" : "\(title), made for \(theme.title)"
    }
}

extension BackgroundTint {
    /// The tint's name in Settings.
    var title: String {
        switch self {
        case .own: "Default"
        case .classic: "Classic"
        case .neutral: "Neutral"
        case .warm: "Warm"
        case .cool: "Cool"
        case .sage: "Sage"
        case .rose: "Rose"
        case .lavender: "Lavender"
        }
    }
}

extension Theme {
    /// The background swatch: the soft fill, an opaque surface every tint
    /// re-hues, as light draws it, its tint three times as strong, so tints
    /// this faint tell apart.
    var backgroundSwatch: NSColor {
        OKLCH.saturated(soft.resolved(in: .light), by: 3)
    }
}

extension Metrics {
    /// The theme, palette, and background pickers.
    public enum ThemePicker {
        /// Between the cards, and between the swatches.
        public static let cardSpacing: CGFloat = 12
        public static let swatchSpacing: CGFloat = 10
        /// A card's preview, and its corner radius.
        public static let previewHeight: CGFloat = 64
        public static let previewRadius: CGFloat = 10
        /// Between a preview and its name.
        public static let nameSpacing: CGFloat = 6
        /// A swatch's diameter.
        public static let swatchSize: CGFloat = 20
    }
}

/// The four themes as cards.
struct ThemeCardPicker: View {
    @Binding var selection: DesignTheme
    /// The palette and the background tint the cards are drawn in.
    let palette: DesignPalette
    let background: BackgroundTint
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.ThemePicker.cardSpacing) {
            ForEach(DesignTheme.allCases, id: \.self) { theme in
                card(theme)
            }
        }
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            move(by: -1)
        }
        .onKeyPress(.rightArrow) {
            move(by: 1)
        }
        .accessibilityRepresentation {
            Picker("Theme", selection: $selection) {
                ForEach(DesignTheme.allCases, id: \.self) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func card(_ theme: DesignTheme) -> some View {
        let isSelected = theme == selection
        let shape = RoundedRectangle(cornerRadius: Metrics.ThemePicker.previewRadius, style: .continuous)
        return VStack(spacing: Metrics.ThemePicker.nameSpacing) {
            ThemePreview(theme: Theme.named(theme, palette: palette, background: background))
                .frame(height: Metrics.ThemePicker.previewHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.line, lineWidth: 1))
                // A palette or background chosen recolors the previews over
                // 0.15 s.
                .motion(Motion.leave, value: palette)
                .motion(Motion.leave, value: background)
                .overlay {
                    SelectionRing(isSelected: isSelected, isFocused: isFocused, shape: shape)
                }
            Text(theme.title)
                .font(isSelected ? Typography.secondary.weight(.semibold) : Typography.secondary)
                .foregroundStyle(isSelected ? .text : .text2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = theme
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let themes = DesignTheme.allCases
        guard let index = themes.firstIndex(of: selection) else {
            return .ignored
        }
        let next = index + offset
        if themes.indices.contains(next) {
            selection = themes[next]
        }
        return .handled
    }
}

/// A small picture of a theme in its own colors: the sidebar with its
/// selected row, a list with a selected row, and the prominent capsule;
/// the list a card on the backdrop in a theme whose panes float, and a card
/// with its ring inset in the backdrop, the sidebar on it, in a theme with
/// the inset card.
struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        let row = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 0) {
            // The sidebar: a selected row and two others.
            VStack(alignment: .leading, spacing: 5) {
                row
                    .fill(Color(nsColor: theme.sidebarSelection))
                    .overlay(alignment: .leading) {
                        bar(Color(nsColor: theme.sidebarSelectionText ?? theme.text3), width: 14)
                            .padding(.leading, 5)
                    }
                    .overlay(alignment: .leading) {
                        if theme.selectionBar {
                            Capsule().fill(Color(nsColor: theme.accent)).frame(width: 2, height: 6)
                        }
                    }
                    .frame(height: 11)
                bar(Color(nsColor: theme.text3), width: 18)
                    .padding(.leading, 5)
                bar(Color(nsColor: theme.text3), width: 12)
                    .padding(.leading, 5)
            }
            .padding(5)
            .frame(width: 38, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: layout == .insetCard ? theme.backdrop : theme.sidebar))
            // The content: a selected row, another, and the prominent
            // capsule.
            VStack(alignment: .leading, spacing: 6) {
                row
                    .fill(Color(nsColor: theme.accentSoft))
                    .overlay(alignment: .leading) {
                        HStack(spacing: 4) {
                            Circle().fill(Color(nsColor: theme.accent)).frame(width: 5, height: 5)
                            bar(Color(nsColor: theme.text2), width: 26)
                        }
                        .padding(.leading, 5)
                    }
                    .frame(height: 12)
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: theme.trunk)).frame(width: 5, height: 5)
                    bar(Color(nsColor: theme.text3), width: 22)
                }
                .padding(.leading, 5)
                Capsule()
                    .fill(Color(nsColor: theme.prominent))
                    .overlay {
                        bar(Color(nsColor: theme.prominentText), width: 14)
                    }
                    .frame(width: 34, height: 12)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                switch layout {
                case .flat:
                    Color(nsColor: theme.background)
                case .floatingCards:
                    // A card on the backdrop.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: theme.background))
                case .insetCard:
                    // The inset card, with its ring.
                    RoundedRectangle(cornerRadius: 4, style: .circular)
                        .fill(Color(nsColor: theme.background))
                        .strokeBorder(Color(nsColor: theme.line), lineWidth: 1)
                }
            }
            .padding(layout.chromeIsBackdrop ? EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 4) : EdgeInsets())
        }
        .background {
            if layout.chromeIsBackdrop {
                Color(nsColor: theme.backdrop)
            }
        }
        .accessibilityHidden(true)
    }

    private var layout: PaneLayout {
        theme.paneLayout
    }

    /// A line of text, as a bar.
    private func bar(_ color: Color, width: CGFloat) -> some View {
        Capsule().fill(color.opacity(0.7)).frame(width: width, height: 3)
    }
}

/// Choices as round swatches, the chosen one ringed: the palettes, or the
/// background tints.
struct SwatchPicker<Value: Hashable>: View {
    private let label: String
    private let values: [Value]
    @Binding private var selection: Value
    private let title: (Value) -> String
    private let fill: (Value) -> NSColor
    @FocusState private var isFocused: Bool
    @Environment(\.motion) private var motion

    init(_ label: String, values: [Value], selection: Binding<Value>, title: @escaping (Value) -> String, fill: @escaping (Value) -> NSColor) {
        self.label = label
        self.values = values
        _selection = selection
        self.title = title
        self.fill = fill
    }

    var body: some View {
        HStack(spacing: Metrics.ThemePicker.swatchSpacing) {
            ForEach(values, id: \.self) { value in
                swatch(value)
            }
        }
        .padding(Metrics.FocusRing.outset)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            move(by: -1)
        }
        .onKeyPress(.rightArrow) {
            move(by: 1)
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(title(value)).tag(value)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func swatch(_ value: Value) -> some View {
        let isSelected = value == selection
        return Circle()
            .fill(Color(nsColor: fill(value)))
            .overlay(Circle().strokeBorder(.line, lineWidth: 1))
            .frame(width: Metrics.ThemePicker.swatchSize, height: Metrics.ThemePicker.swatchSize)
            .overlay {
                SelectionRing(isSelected: isSelected, isFocused: isFocused, shape: Circle())
            }
            .contentShape(Circle())
            .onTapGesture {
                choose(value)
            }
            .tooltip(title(value))
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard let index = values.firstIndex(of: selection) else {
            return .ignored
        }
        let next = index + offset
        if values.indices.contains(next) {
            choose(values[next])
        }
        return .handled
    }

    /// Picks `value`: what the choice changes in the pane (the row's name
    /// for it, the background swatches' colors) crossfades over 0.15 s with
    /// the ring. The swatches a theme change brings show at once.
    private func choose(_ value: Value) {
        withMotion(motion, Motion.leave) {
            selection = value
        }
    }
}

/// The ring around the chosen card or swatch, drawn as the focus ring is:
/// it fades in settling from 1.04× to its size, and fades out, over 0.15 s,
/// so a new choice crossfades it from one to the other.
private struct SelectionRing<RingShape: InsettableShape>: View {
    let isSelected: Bool
    let isFocused: Bool
    let shape: RingShape
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            if isSelected {
                shape
                    .inset(by: -Metrics.FocusRing.outset)
                    .strokeBorder(
                        Color.accent.opacity(isFocused ? 1 : Metrics.FocusRing.opacity),
                        lineWidth: Metrics.FocusRing.lineWidth
                    )
                    .transition(transition)
            }
        }
        .motion(Motion.leave, value: isSelected)
    }

    private var transition: AnyTransition {
        guard motion.animates else {
            return .identity
        }
        return .asymmetric(
            insertion: .scale(scale: Motion.focusRingScale).combined(with: .opacity),
            removal: .opacity
        )
    }
}

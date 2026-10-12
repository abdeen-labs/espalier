// Settings ▸ Appearance's theme and color pickers, Espalier's own controls.
// The theme is four cards, each a small preview drawn in its theme's
// colors (the sidebar with its selection, a selected row, the prominent
// capsule) with the theme's name under it; the chosen card has the
// focus-ring-style accent ring. A theme's colors are round swatches, the
// chosen one ringed. Each picker is one stop in the key view loop: the left
// and right arrows move the choice, and VoiceOver sees a radio group.

import EspalierCore
import SwiftUI

extension DesignTheme {
    /// The theme's name in Settings.
    var title: String {
        switch self {
        case .classic: "Classic"
        case .orchard: "Orchard"
        case .islands: "Islands"
        case .pop: "Pop"
        }
    }
}

extension DesignThemeColor {
    /// The color's name in Settings.
    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

extension Metrics {
    /// The theme and color pickers.
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
    /// Each theme's color, for its card.
    let colors: [DesignTheme: DesignThemeColor]
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
            ThemePreview(theme: Theme.named(theme, color: colors[theme]))
                .frame(height: Metrics.ThemePicker.previewHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.line, lineWidth: 1))
                .overlay {
                    if isSelected {
                        shape
                            .inset(by: -Metrics.FocusRing.outset)
                            .strokeBorder(
                                Color.accent.opacity(isFocused ? 1 : Metrics.FocusRing.opacity),
                                lineWidth: Metrics.FocusRing.lineWidth
                            )
                    }
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
/// the list a card on the backdrop in a theme whose panes float.
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
            .background(Color(nsColor: theme.sidebar))
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
                if floats {
                    // A card on the backdrop.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: theme.background))
                } else {
                    Color(nsColor: theme.background)
                }
            }
            .padding(floats ? EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 4) : EdgeInsets())
        }
        .background {
            if floats {
                Color(nsColor: theme.backdrop)
            }
        }
        .accessibilityHidden(true)
    }

    /// Whether the theme floats its panes as cards.
    private var floats: Bool {
        theme.paneLayout == .floatingCards
    }

    /// A line of text, as a bar.
    private func bar(_ color: Color, width: CGFloat) -> some View {
        Capsule().fill(color.opacity(0.7)).frame(width: width, height: 3)
    }
}

/// A theme's colors as round swatches, the chosen one ringed.
struct ThemeColorPicker: View {
    let theme: DesignTheme
    @Binding var selection: DesignThemeColor
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.ThemePicker.swatchSpacing) {
            ForEach(theme.colors, id: \.self) { color in
                swatch(color)
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
            Picker("Color", selection: $selection) {
                ForEach(theme.colors, id: \.self) { color in
                    Text(color.title).tag(color)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func swatch(_ color: DesignThemeColor) -> some View {
        let isSelected = color == selection
        return Circle()
            .fill(Color(nsColor: Theme.named(theme, color: color).accent))
            .overlay(Circle().strokeBorder(.line, lineWidth: 1))
            .frame(width: Metrics.ThemePicker.swatchSize, height: Metrics.ThemePicker.swatchSize)
            .overlay {
                if isSelected {
                    Circle()
                        .inset(by: -Metrics.FocusRing.outset)
                        .strokeBorder(
                            Color.accent.opacity(isFocused ? 1 : Metrics.FocusRing.opacity),
                            lineWidth: Metrics.FocusRing.lineWidth
                        )
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                selection = color
            }
            .tooltip(color.title)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard let index = theme.colors.firstIndex(of: selection) else {
            return .ignored
        }
        let next = index + offset
        if theme.colors.indices.contains(next) {
            selection = theme.colors[next]
        }
        return .handled
    }
}

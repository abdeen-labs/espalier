// Espalier's links: the accent (`Palette.link`, deepened just enough to read
// as text) in the text's own font and weight, underlined while the pointer
// is over them, dimmed while pressed, with the pointing hand. Three forms
// share the look: `.textLink`, a button style for actions that read as links
// ("Skip This Step"); `TextLink`, a link to a URL, which opens it through the
// environment's `openURL` as every link in Espalier does; and `LinkedText`,
// text with links in it (Markdown, `AttributedString` links), whose links
// take the color and underline while the pointer is over the text. With the
// Underline links setting, text that underlines its links keeps them
// underlined.

import SwiftUI

// MARK: - Buttons

/// A button that reads as a link: its label in the link color, underlined
/// while the pointer is over it, dimmed while pressed, with the focus ring
/// around it.
public struct TextLinkButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: TextLinkDrawing())
    }
}

extension PrimitiveButtonStyle where Self == TextLinkButtonStyle {
    /// A link: the label in the link color, underlined on hover.
    public static var textLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}

/// Draws a link button, its focus ring included.
private struct TextLinkDrawing: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextLinkBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// A link's label: underlined while the pointer is over it.
private struct TextLinkBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let color = Color(nsColor: Palette.link)
        let isUnderlined = isEnabled && isHovered
        label
            .foregroundStyle(color)
            .underline(isUnderlined, color: color)
            .opacity(isEnabled ? (isPressed ? Metrics.FocusRing.pressedOpacity : 1) : Palette.disabledOpacity)
            .pressMotion(isPressed)
            .contentShape(Rectangle())
            .focusRing(isFocused, in: RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .continuous))
            .pointerStyle(isEnabled ? .link : nil)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Links to URLs

/// A link to a URL in Espalier's look. A click opens it through the
/// environment's `openURL`, as `Link` would, so a view that routes the
/// app's links (to the browser setting, to an action) routes this one too.
/// VoiceOver sees a link.
public struct TextLink<Label: View>: View {
    private let destination: URL
    private let label: Label
    @Environment(\.openURL) private var openURL

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        Button {
            openURL(destination)
        } label: {
            label
        }
        .buttonStyle(.textLink)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
    }
}

extension TextLink where Label == Text {
    /// A link titled `title`, as it is.
    public init(_ title: String, destination: URL) {
        self.init(destination: destination) {
            Text(title)
        }
    }
}

// MARK: - Links in text

/// Text with links in it, in Espalier's look: the links in the link color,
/// underlined while the pointer is over the text. A click on one opens it
/// through the environment's `openURL`.
public struct LinkedText: View {
    /// The text as given, before the links' styling.
    let text: AttributedString
    @State private var isHovered = false

    public init(_ text: AttributedString) {
        self.text = text
    }

    /// Text from Markdown, whose `[title](url)` links are links; text that
    /// isn't Markdown shows as it is.
    public init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    public var body: some View {
        Text(Self.styled(text, underlined: isHovered))
            .tint(Color(nsColor: Palette.link))
            .onHover { isHovered = $0 }
    }

    /// `text` with its links in the link color, and underlined when
    /// `underlined` (links it already underlines stay underlined).
    nonisolated static func styled(_ text: AttributedString, underlined: Bool) -> AttributedString {
        guard text.runs.contains(where: { $0.link != nil }) else {
            return text
        }
        let color = Color(nsColor: Palette.link)
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(text[run.range])
            if run.link != nil {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color
                if underlined {
                    piece[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
                }
            }
            result.append(piece)
        }
        return result
    }
}

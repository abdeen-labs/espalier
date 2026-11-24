// The note the composer shows while amending, with Stop amending as a link,
// on a banner.

import SwiftUI

/// "Your changes will modify your most recent commit."
public struct AmendBanner: View {
    private let onStopAmending: () -> Void

    public init(onStopAmending: @escaping () -> Void = {}) {
        self.onStopAmending = onStopAmending
    }

    public var body: some View {
        // A banner in the accent, or the symbol and the note on a quiet
        // card, as the theme has it.
        Group {
            if ComposerView.isSplit {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(Color.accent)
                        .accessibilityHidden(true)
                    note(color: .text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.Composer.cardPadding)
                .padding(.vertical, Metrics.insetSmall)
                .surface(.quiet, elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
            } else {
                SoftBanner(color: Palette.accent) {
                    SoftBannerSymbol("pencil", color: Palette.accent)
                } message: {
                    note(color: .text)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Stop Amending", onStopAmending)
    }

    private func note(color: Color) -> some View {
        LinkedText(Self.message)
            .font(Typography.secondary)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { _ in
                onStopAmending()
                return .handled
            })
    }

    /// The note, with "most recent commit" in bold and "Stop amending" as
    /// a link.
    static let message: AttributedString = {
        var lead = AttributedString("Your changes will modify your ")
        var emphasis = AttributedString("most recent commit")
        emphasis.inlinePresentationIntent = .stronglyEmphasized
        var link = AttributedString("Stop amending")
        link.link = URL(string: "espalier-composer:stop-amending")
        let tail = AttributedString(" to make them a new commit.")
        lead.append(emphasis)
        lead.append(AttributedString(". "))
        lead.append(link)
        lead.append(tail)
        return lead
    }()
}

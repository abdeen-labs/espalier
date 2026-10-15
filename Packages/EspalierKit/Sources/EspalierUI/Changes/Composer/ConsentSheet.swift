// The sheet before the first request to a provider: it says what is sent and
// where (AIKit's `getAIDataDisclosure`), and records the consent. The
// commit message's and the conflicts' sheets share its layout.

import AIKit
import SwiftUI

/// What the consent sheet says.
nonisolated public struct AIConsentContent: Sendable, Equatable {
    public var providerName: String
    /// One sentence naming the provider and where requests go.
    public var summary: String
    /// What is sent, one item per entry.
    public var sentData: [String]
    /// The disclaimer: results need review.
    public var reviewAdvice: String
    /// What the user agrees to (`AIDataDisclosure.consentIdentifier`).
    public var consentIdentifier: String

    public init(providerName: String, summary: String, sentData: [String], reviewAdvice: String, consentIdentifier: String) {
        self.providerName = providerName
        self.summary = summary
        self.sentData = sentData
        self.reviewAdvice = reviewAdvice
        self.consentIdentifier = consentIdentifier
    }

    public init(_ disclosure: AIDataDisclosure) {
        self.init(
            providerName: disclosure.providerName,
            summary: disclosure.summary,
            sentData: disclosure.sentData,
            reviewAdvice: disclosure.reviewAdvice,
            consentIdentifier: disclosure.consentIdentifier
        )
    }

    /// The sheet's title.
    public var title: String {
        "Send Changes to \(providerName)?"
    }
}

/// "Send Changes to <provider>?" with what's sent, Cancel, and Continue.
public struct ConsentSheet: View {
    /// The sheet's id for `ModalPresenter`.
    public static let sheetID = "changes.ai-consent"

    private let content: AIConsentContent
    private let onAnswer: (Bool) -> Void
    @Environment(\.dismissModal) private var dismissModal

    /// - Parameters:
    ///   - onAnswer: Continue (true) or Cancel (false); the sheet closes
    ///     either way.
    public init(_ content: AIConsentContent, onAnswer: @escaping (Bool) -> Void = { _ in }) {
        self.content = content
        self.onAnswer = onAnswer
    }

    public var body: some View {
        AIConsentScaffold(content.title, content: content) {
            answer(false)
        } confirm: {
            answer(true)
        }
    }

    private func answer(_ isConfirmed: Bool) {
        onAnswer(isConfirmed)
        dismissModal()
    }
}

/// A consent sheet's layout, which every feature's shares: the title, the
/// summary under it, what's sent as a bulleted list in a card, the advice
/// to review the results, then Cancel and Continue.
struct AIConsentScaffold: View {
    private let title: String
    private let content: AIConsentContent
    private let cancel: () -> Void
    private let confirm: () -> Void

    init(_ title: String, content: AIConsentContent, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.title = title
        self.content = content
        self.cancel = cancel
        self.confirm = confirm
    }

    var body: some View {
        SheetScaffold(title, message: content.summary) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                ForEach(Array(content.sentData.enumerated()), id: \.offset) { _, item in
                    BulletItem(text: item)
                        .font(Typography.secondary)
                        .foregroundStyle(.text)
                }
            }
            .padding(Metrics.insetMedium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .fill(.field)
            )
            Text(content.reviewAdvice)
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            SheetButtons("Continue", cancel: cancel, confirm: confirm)
        }
    }
}

/// A bulleted line; wrapped lines align with the text, not the bullet.
private struct BulletItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Text(verbatim: "•")
                .foregroundStyle(.text2)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

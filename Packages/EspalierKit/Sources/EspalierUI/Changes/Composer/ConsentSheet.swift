// The sheet before the first request to a provider: it says what is sent and
// where (AIKit's `getAIDataDisclosure`), and records the consent.

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
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            Label(content.title, systemImage: "sparkles")
                .font(Typography.heading)
            Text(content.summary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Metrics.grid) {
                ForEach(Array(content.sentData.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "circle.fill")
                        .labelStyle(RuleBulletLabelStyle())
                }
            }
            .font(Typography.secondary)
            Text(content.reviewAdvice)
                .font(Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.insetSmall) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) {
                    answer(false)
                }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    answer(true)
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.insetLarge)
        .frame(width: Metrics.Sheet.standardWidth, alignment: .leading)
    }

    private func answer(_ isConfirmed: Bool) {
        onAnswer(isConfirmed)
        dismissModal()
    }
}

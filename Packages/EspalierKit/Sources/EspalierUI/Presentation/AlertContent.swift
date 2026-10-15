// One value describes every alert Espalier shows (confirmations, errors,
// prompts, the quit guard, state notices), so one card draws them all
// (`AlertCard`).

import Foundation
import GitKit

/// An alert: a title, a message, buttons, and an optional suppression
/// checkbox.
nonisolated public struct AlertContent: Sendable, Equatable {
    /// How serious the alert is.
    public enum Severity: Sendable, Equatable {
        case standard
        /// Discards, deletions, and force pushes: the warning glyph before
        /// the title.
        case critical
    }

    /// A button's role.
    public enum Role: Sendable, Equatable {
        /// The default button (Return).
        case primary
        /// A destructive action.
        case destructive
        /// Another action.
        case secondary
        /// Dismisses (Escape).
        case cancel
    }

    /// A button.
    public struct Button: Sendable, Equatable {
        public var title: String
        public var role: Role

        public init(_ title: String, role: Role) {
            self.title = title
            self.role = role
        }
    }

    public var title: String
    public var message: String
    /// In order: the first is the default button (rightmost, Return), then
    /// the others leftward. The cancel-role button answers Escape and ⌘.
    public var buttons: [Button]
    /// The suppression checkbox's title ("Do not show this message again"),
    /// or nil for none.
    public var suppressionTitle: String?
    public var severity: Severity

    public init(title: String, message: String, buttons: [Button], suppressionTitle: String? = nil, severity: Severity = .standard) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.suppressionTitle = suppressionTitle
        self.severity = severity
    }

    /// The suppression checkbox's title.
    public static let doNotShowAgain = "Do not show this message again"
}

/// What the user chose in an alert.
nonisolated public struct AlertResponse: Sendable, Equatable {
    /// The index of the button in `AlertContent.buttons`.
    public var buttonIndex: Int
    /// Whether the suppression checkbox was on.
    public var isSuppressed: Bool

    public init(buttonIndex: Int, isSuppressed: Bool = false) {
        self.buttonIndex = buttonIndex
        self.isSuppressed = isSuppressed
    }
}

extension AlertContent {
    /// The answer for the button at `buttonIndex`, with the checkbox's
    /// state whatever the button. An alert closed without a button
    /// (`ModalPresenter.dismissAlert(id:)`), or an index that isn't a
    /// button's, answers with the cancel button, or the last.
    func response(buttonIndex: Int?, isSuppressed: Bool) -> AlertResponse {
        let index = buttonIndex.flatMap { buttons.indices.contains($0) ? $0 : nil } ?? cancelIndex
        return AlertResponse(buttonIndex: index, isSuppressed: isSuppressed)
    }

    /// The index of the cancel button, or the last button.
    public var cancelIndex: Int {
        buttons.firstIndex { $0.role == .cancel } ?? max(buttons.count - 1, 0)
    }

    /// The button Escape and ⌘. press: the cancel button, or an alert's
    /// only button. Nil when no button cancels.
    var escapeIndex: Int? {
        if let cancel = buttons.firstIndex(where: { $0.role == .cancel }) {
            return cancel
        }
        return buttons.count == 1 ? 0 : nil
    }
}

/// Lists in alert messages (files, authors).
nonisolated enum AlertList {
    /// At most this many items are listed; the rest are counted.
    static let maximumItems = 10

    /// The items as lines, at most `maximumItems`, then "and N more" (the
    /// count in `numberFormat`).
    static func lines(_ items: [String], numberFormat: NumberFormat) -> String {
        var lines = items.prefix(maximumItems).map { "• \($0)" }
        if items.count > maximumItems {
            lines.append("and \(formatCount(items.count - maximumItems, numberFormat)) more")
        }
        return lines.joined(separator: "\n")
    }

    /// `message` with `items` listed after its first paragraph, right after
    /// the question.
    static func insert(_ items: [String], intoMessage message: String, numberFormat: NumberFormat) -> String {
        guard !items.isEmpty else {
            return message
        }
        let paragraphs = message.components(separatedBy: "\n\n")
        guard let first = paragraphs.first else {
            return lines(items, numberFormat: numberFormat)
        }
        return ([first, lines(items, numberFormat: numberFormat)] + paragraphs.dropFirst()).joined(separator: "\n\n")
    }
}

// The composer's commit button: its labels, when it's enabled, and its
// tooltips.

import EspalierCore
import GitKit
import SwiftUI

/// What the commit button shows.
nonisolated public struct CommitButtonContent: Sendable, Equatable {
    /// Amending the last commit rather than making a new one.
    public var isAmending: Bool
    /// The files the commit includes (in full or in part).
    public var fileCount: Int
    /// The branch the commit goes on (an unborn branch's name too); nil on a
    /// detached HEAD.
    public var branch: String?
    public var isCommitting: Bool
    /// A commit message is being generated.
    public var isGenerating: Bool
    public var isEnabled: Bool
    /// Why the button is disabled, for its tooltip.
    public var disabledReason: String?
    public var numberFormat: NumberFormat

    public init(
        isAmending: Bool = false,
        fileCount: Int,
        branch: String?,
        isCommitting: Bool = false,
        isGenerating: Bool = false,
        isEnabled: Bool,
        disabledReason: String? = nil,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.isAmending = isAmending
        self.fileCount = fileCount
        self.branch = branch
        self.isCommitting = isCommitting
        self.isGenerating = isGenerating
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.numberFormat = numberFormat
    }

    /// The label's parts: the words before the branch, the branch (shown
    /// bold), and what follows it.
    public var titleParts: (lead: String, branch: String?, trail: String) {
        if isGenerating {
            return ("Generating Commit Details…", nil, "")
        }
        if isAmending {
            return (isCommitting ? "Amending Last Commit…" : "Amend Last Commit", nil, "")
        }
        var words = [isCommitting ? "Committing" : "Commit"]
        if fileCount > 0 {
            words.append("\(formatNumber(Double(fileCount), numberFormat)) \(fileCount == 1 ? "File" : "Files")")
        }
        let trail = isCommitting ? "…" : ""
        guard let branch else {
            return (words.joined(separator: " "), nil, trail)
        }
        words.append("to")
        return (words.joined(separator: " "), branch, trail)
    }

    /// The label the button shows: the title without the branch, which the
    /// commit message card's footer names ("Commit 2 Files").
    public var shownTitle: String {
        let parts = titleParts
        guard parts.branch != nil else {
            return parts.lead + parts.trail
        }
        let lead = parts.lead.hasSuffix(" to") ? String(parts.lead.dropLast(3)) : parts.lead
        return lead + parts.trail
    }

    /// The label as one string: "Commit 2 Files to main".
    public var title: String {
        let parts = titleParts
        return parts.lead + (parts.branch.map { " \($0)" } ?? "") + parts.trail
    }

    /// The tooltip: the title, or why the button is disabled.
    public var help: String {
        if isGenerating || isEnabled {
            return title
        }
        return disabledReason ?? title
    }
}

/// The commit button: the full-width prominent capsule, 34 high, with its
/// shortcut on the right.
public struct CommitButton: View {
    private let content: CommitButtonContent
    private let action: () -> Void

    public init(_ content: CommitButtonContent, action: @escaping () -> Void = {}) {
        self.content = content
        self.action = action
    }

    public var body: some View {
        Group {
            if content.isCommitting || content.isGenerating {
                // While it works, the capsule stays legible rather than
                // fading as a disabled button does (as the sync button).
                HStack(spacing: Metrics.insetSmall) {
                    ArcProgress(.small, tint: .white)
                    label
                }
                .frame(maxWidth: .infinity)
                .capsuleChrome(.prominent)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
            } else {
                Button(action: action) {
                    label
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            if let shortcut = ActionKind.commitChanges.shortcut?.symbols {
                                Text(shortcut)
                                    .font(Typography.keyCap)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.prominent)
                .disabled(!content.isEnabled)
            }
        }
        .controlSize(.extraLarge)
        .help(content.help)
        .accessibilityLabel(content.title)
    }

    /// The title; its count rolls over 0.2 s as checkboxes change it.
    private var label: some View {
        Text(content.shownTitle)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentTransition(.numericText())
            .motion(Motion.kindChange, value: content.fileCount)
    }
}

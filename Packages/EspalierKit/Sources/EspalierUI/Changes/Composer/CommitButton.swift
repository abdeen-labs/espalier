// The commit button: Commit (with the files and the branch) in the commit
// form; Commit Merge while a merge waits, or Continue while a rebase,
// cherry-pick, or revert does, for the operation panel's button; its
// labels, when it's enabled, and its tooltips.

import EspalierCore
import GitKit
import SwiftUI

/// What the commit button shows.
nonisolated public struct CommitButtonContent: Sendable, Equatable {
    /// What the button does.
    public enum Kind: Sendable, Equatable {
        /// Commits the included changes, or amends the last commit.
        case commit
        /// Commits the merge waiting on its conflicts, with the message the
        /// form shows.
        case merge
        /// Continues the operation waiting on the user ("Rebase",
        /// "Cherry-pick", "Revert", "Squash", "Reorder").
        case continueOperation(name: String)
    }

    public var kind: Kind
    /// Amending the last commit rather than making a new one.
    public var isAmending: Bool
    /// The files the commit includes (in full or in part).
    public var fileCount: Int
    /// The branch the commit goes on (an unborn branch's name too); nil on a
    /// detached HEAD.
    public var branch: String?
    /// The commit, or the merge or continue, runs.
    public var isCommitting: Bool
    /// A commit message is being generated.
    public var isGenerating: Bool
    public var isEnabled: Bool
    /// Why the button is disabled, for its tooltip.
    public var disabledReason: String?
    public var numberFormat: NumberFormat

    public init(
        kind: Kind = .commit,
        isAmending: Bool = false,
        fileCount: Int,
        branch: String?,
        isCommitting: Bool = false,
        isGenerating: Bool = false,
        isEnabled: Bool,
        disabledReason: String? = nil,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.kind = kind
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
    /// bold, truncated in the middle when it doesn't fit), and what follows
    /// it.
    public var titleParts: (lead: String, branch: String?, trail: String) {
        switch kind {
        case .merge:
            return (isCommitting ? "Committing Merge…" : "Commit Merge", nil, "")
        case .continueOperation(let name):
            return (isCommitting ? "Continuing \(name)…" : "Continue \(name)", nil, "")
        case .commit:
            break
        }
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
/// shortcut on the right. A long branch name gives way in the middle, so
/// the button never grows past its column; the count rolls over 0.2 s as
/// files are included or leave. The button and its working capsule (the arc
/// and "Committing…") crossfade over 0.2 s as work starts and ends.
public struct CommitButton: View {
    private let content: CommitButtonContent
    private let action: () -> Void
    @Environment(\.motion) private var motion

    public init(_ content: CommitButtonContent, action: @escaping () -> Void = {}) {
        self.content = content
        self.action = action
    }

    public var body: some View {
        // The crossfade carries its own motion, so the button moves as the
        // composer around it does.
        let fade: AnyTransition = motion.animates ? .opacity.animation(Motion.animation(Motion.kindChange)) : .identity
        // One over the other while they crossfade.
        ZStack {
            if content.isCommitting || content.isGenerating {
                // While it works, the capsule stays legible rather than
                // fading as a disabled button does (as the sync button).
                HStack(spacing: Metrics.insetSmall) {
                    ArcProgress(.small, tint: Palette.buttonText)
                    label
                }
                .frame(maxWidth: .infinity)
                .capsuleChrome(.prominent)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .tooltip(content.help)
                .accessibilityLabel(content.title)
                .transition(fade)
            } else {
                Button(action: action) {
                    if let symbols = shortcutSymbols {
                        // The shortcut's hidden twin on the left keeps the
                        // title centered while the whole title fits; when
                        // it doesn't, the title takes the twin's room too.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Metrics.insetSmall) {
                                shortcut(symbols)
                                    .hidden()
                                label
                                    .frame(maxWidth: .infinity)
                                shortcut(symbols)
                            }
                            HStack(spacing: Metrics.insetSmall) {
                                label
                                    .frame(maxWidth: .infinity)
                                shortcut(symbols)
                            }
                        }
                    } else {
                        label
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.prominent)
                .disabled(!content.isEnabled)
                .tooltip(content.help)
                .accessibilityLabel(content.title)
                .transition(fade)
            }
        }
        .controlSize(.extraLarge)
    }

    /// ⌘↩, which Commit Changes runs: it presses Commit, or runs Commit
    /// Merge or Continue while an operation waits.
    private var shortcutSymbols: String? {
        ActionKind.commitChanges.shortcut?.symbols
    }

    private func shortcut(_ symbols: String) -> some View {
        Text(symbols)
            .font(Typography.keyCap)
            .foregroundStyle(Color.prominentText.opacity(0.7))
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// The title: the words keep their room and the branch gives way, in
    /// the middle. Its count rolls to a new one.
    private var label: some View {
        let parts = content.titleParts
        return Group {
            if let branch = parts.branch {
                HStack(spacing: 0) {
                    Text(parts.lead)
                        .layoutPriority(2)
                    // The space leads the branch's text: a trailing one
                    // would be trimmed.
                    Text(verbatim: " " + branch)
                        .fontWeight(.bold)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if !parts.trail.isEmpty {
                        Text(parts.trail)
                            .layoutPriority(2)
                    }
                }
                .lineLimit(1)
            } else {
                Text(parts.lead + parts.trail)
                    .lineLimit(1)
            }
        }
        .contentTransition(motion.animates ? .numericText() : .identity)
        .motion(Motion.kindChange, value: content.fileCount)
    }
}

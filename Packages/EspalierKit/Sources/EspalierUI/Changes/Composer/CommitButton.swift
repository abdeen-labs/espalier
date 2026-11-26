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
    /// Committing with AI (`CommitMode.assisted`): the selected changes
    /// split into commits.
    public var isAssisted: Bool
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
    /// The commit is pushed once it's made (Push After Committing): the
    /// button reads "Commit and Push".
    public var pushes: Bool
    /// What committing and pushing will do, under the button: "Commits 2
    /// files, then pushes 4 commits to origin".
    public var pushCaption: String?

    public init(
        kind: Kind = .commit,
        isAssisted: Bool = false,
        isAmending: Bool = false,
        fileCount: Int,
        branch: String?,
        isCommitting: Bool = false,
        isGenerating: Bool = false,
        isEnabled: Bool,
        disabledReason: String? = nil,
        numberFormat: NumberFormat = defaultNumberFormat,
        pushes: Bool = false,
        pushCaption: String? = nil
    ) {
        self.pushes = pushes
        self.pushCaption = pushCaption
        self.kind = kind
        self.isAssisted = isAssisted
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
        if isAssisted, isCommitting {
            return ("Committing with AI…", nil, "")
        }
        if pushes, !isAssisted {
            return (isCommitting ? "Committing…" : "Commit and Push", nil, "")
        }
        var words = [isCommitting ? "Committing" : "Commit"]
        if fileCount > 0 {
            words.append("\(formatNumber(Double(fileCount), numberFormat)) \(fileCount == 1 ? "File" : "Files")")
        }
        // An empty commit asks no model.
        let trail = isCommitting ? "…" : isAssisted && fileCount > 0 ? " with AI" : ""
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

    /// What committing and pushing will do: "Commits 2 files, then pushes 4
    /// commits to origin", or "…, then publishes feature to origin" for a
    /// branch not yet on the remote (numbers in the user's format).
    ///
    /// - Parameters:
    ///   - fileCount: The files the commit includes.
    ///   - commitsToPush: The commits the push sends, the one about to be
    ///     made included; nil when the branch isn't published.
    ///   - branch: The branch, which a publish names.
    ///   - remote: Where the push goes.
    public static func pushCaption(fileCount: Int, commitsToPush: Int?, branch: String, remote: String, numberFormat: NumberFormat) -> String {
        let commits = fileCount == 0
            ? "Commits"
            : "Commits \(formatCount(fileCount, numberFormat)) \(fileCount == 1 ? "file" : "files")"
        guard let commitsToPush else {
            return "\(commits), then publishes \(branch) to \(remote)"
        }
        return "\(commits), then pushes \(formatCount(commitsToPush, numberFormat)) \(commitsToPush == 1 ? "commit" : "commits") to \(remote)"
    }

    /// The tooltip: the title, or why the button is disabled.
    public var help: String {
        if isGenerating || isEnabled {
            return title
        }
        return disabledReason ?? title
    }
}

/// The commit button, as the theme has it (`ChangesThemeStyle.panes`): a
/// big full-width pillow, 44 high, that names the branch as a candy pill;
/// or the full-width prominent capsule, 34 high, with the branch in bold.
/// Its shortcut is on the right. A long branch name gives way in the
/// middle, so the button never grows past its column; the count rolls over
/// 0.2 s as files are included or leave. The button and its working
/// pillow or capsule (the arc and "Committing…") crossfade over 0.2 s as
/// work starts and ends.
public struct CommitButton: View {
    private let content: CommitButtonContent
    private let action: () -> Void
    @Environment(\.motion) private var motion

    public init(_ content: CommitButtonContent, action: @escaping () -> Void = {}) {
        self.content = content
        self.action = action
    }

    /// The prominent capsule with the branch in bold, rather than the
    /// pillow with its pill.
    private var isCapsule: Bool {
        ComposerView.isSplit
    }

    public var body: some View {
        // The crossfade carries its own motion, so the button moves as the
        // composer around it does.
        let fade: AnyTransition = motion.animates ? .opacity.animation(Motion.animation(Motion.kindChange)) : .identity
        // One over the other while they crossfade.
        let button = ZStack {
            if content.isCommitting || content.isGenerating {
                // While it works, the button stays legible rather than
                // fading as a disabled button does (as the sync button).
                working
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
                            // The narrowest: the shortcut leaves the branch
                            // its room.
                            label
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        label
                            .frame(maxWidth: .infinity)
                    }
                }
                .commitButtonStyle(isCapsule: isCapsule)
                .disabled(!content.isEnabled)
                .tooltip(content.help)
                .accessibilityLabel(content.title)
                .transition(fade)
            }
        }
        if isCapsule {
            button
                .controlSize(.extraLarge)
        } else {
            button
        }
    }

    /// The arc and the title on the button's own chrome.
    @ViewBuilder
    private var working: some View {
        let content = HStack(spacing: Metrics.insetSmall) {
            ArcProgress(.small, tint: Palette.buttonText)
            label
        }
        if isCapsule {
            content
                .frame(maxWidth: .infinity)
                .capsuleChrome(.prominent)
        } else {
            content
                .pillowChrome()
        }
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

    /// The title: the words keep their room and the branch, in bold or in
    /// its candy pill, gives way in the middle. Its count rolls to a new
    /// one.
    private var label: some View {
        let parts = content.titleParts
        return Group {
            if let branch = parts.branch, isCapsule {
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
            } else if let branch = parts.branch {
                HStack(spacing: Metrics.CommitButton.pillSpacing) {
                    Text(parts.lead)
                        .layoutPriority(2)
                    BranchPill(branch)
                        .layoutPriority(1)
                    if !parts.trail.isEmpty, !content.isCommitting {
                        // " with AI" follows the pill; its space is the
                        // stack's. A commit under way ends at the pill:
                        // the arc says it's working, and its "…" would
                        // stand alone after the pill.
                        Text(parts.trail.trimmingCharacters(in: .whitespaces))
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

extension Button {
    /// The commit button's style: the prominent capsule, or the pillow.
    @ViewBuilder
    fileprivate func commitButtonStyle(isCapsule: Bool) -> some View {
        if isCapsule {
            buttonStyle(.prominent)
        } else {
            buttonStyle(.pillow)
        }
    }
}

/// The branch on the commit button: a candy pill of the button's own text
/// color on the prominent fill, the branch symbol, and the name, which
/// gives way in the middle.
private struct BranchPill: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        HStack(spacing: Metrics.TintedPill.symbolSpacing) {
            Image(systemName: PlaceIdentity.branches.systemImage)
                .imageScale(.small)
                .fontWeight(.bold)
            Text(verbatim: name)
                .fontWeight(.bold)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color.prominentText)
        .padding(.horizontal, Metrics.CommitButton.pillPadding)
        .padding(.vertical, Metrics.TintedPill.verticalPadding + 1)
        .background(Capsule(style: .continuous).fill(Color.prominentText.opacity(Metrics.CommitButton.pillOpacity)))
    }
}

extension Metrics {
    /// The commit button's branch pill.
    public enum CommitButton {
        /// Between the words and the pill.
        public static let pillSpacing: CGFloat = 6
        public static let pillPadding: CGFloat = 9
        /// The pill's fill: the button's text color at this opacity.
        public static let pillOpacity: Double = 0.2
    }
}

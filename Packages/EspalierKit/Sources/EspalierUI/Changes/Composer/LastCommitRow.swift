// The composer's last-commit row: the newest unpushed commit, when it can be
// undone, with Undo. It shows when there's an `undoableCommitSHA`, and Undo
// is disabled while the repository is being updated.

import EspalierCore
import GitKit
import SwiftUI

/// What the last-commit row shows.
nonisolated public struct LastCommitContent: Sendable, Equatable {
    public var summary: String
    /// When the commit was authored.
    public var date: Date
    public var isUndoEnabled: Bool

    public init(summary: String, date: Date, isUndoEnabled: Bool = true) {
        self.summary = summary
        self.date = date
        self.isUndoEnabled = isUndoEnabled
    }

    /// Undo's tooltip: why it's disabled, when it is.
    public var undoHelp: String {
        isUndoEnabled ? "Undo this commit and keep its changes" : "Undo is disabled while the repository is being updated"
    }
}

extension LastCommitContent {
    /// The row for the newest local commit, when Undo applies to it: no
    /// tags, not amending, no operation waiting on conflicts
    /// (`undoableCommitSHA`). Undo waits while a push, pull, fetch, commit,
    /// or other operation runs.
    @MainActor
    public static func make(_ repository: RepositoryModel) -> LastCommitContent? {
        guard let commit = repository.commit.mostRecentLocalCommit,
              let undoable = repository.commit.undoableCommitSHA, undoable == commit.sha
        else {
            return nil
        }
        return LastCommitContent(
            summary: RichText.emojified(commit.summary),
            date: commit.author.date,
            isUndoEnabled: repository.localOperation == nil && repository.networkOperation == nil
        )
    }
}

/// "Committed 2 minutes ago", the summary, and Undo. Another commit's row
/// crossfades in (Changes' column sets the motion).
public struct LastCommitRow: View {
    private let content: LastCommitContent
    private let onUndo: () -> Void
    @Environment(\.motion) private var motion

    public init(_ content: LastCommitContent, onUndo: @escaping () -> Void = {}) {
        self.content = content
        self.onUndo = onUndo
    }

    /// Which commit the row is for, as far as it shows.
    private struct Shown: Hashable {
        var summary: String
        var date: Date
    }

    public var body: some View {
        // One over the other while they crossfade.
        ZStack {
            row
                .id(Shown(summary: content.summary, date: content.date))
                .transition(motion.animates ? .opacity : .identity)
        }
    }

    private var row: some View {
        HStack(spacing: Metrics.insetSmall) {
            VStack(alignment: .leading, spacing: Metrics.grid / 2) {
                CommittedDateText(date: content.date)
                    .font(Typography.meta)
                    .foregroundStyle(.text3)
                Text(content.summary)
                    .font(Typography.row.weight(.medium))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Metrics.insetSmall)
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .disabled(!content.isUndoEnabled)
            .tooltip(content.undoHelp)
        }
    }
}

/// "Committed 2 minutes ago", refreshed once a minute, with the date and
/// time in the tooltip.
struct CommittedDateText: View {
    let date: Date
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        TimelineView(.everyMinute) { context in
            text(now: context.date)
        }
    }

    private func text(now: Date) -> some View {
        Text("Committed \(RelativeTime.describe(date, now: now, formatting: formatting, timeZone: timeZone))")
            .tooltip(RelativeTime.formatDate(date, formatting: formatting, timeZone: timeZone))
    }
}

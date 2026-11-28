// Changes' All Work scope, shown by Branch ▸ Show All Work and Home's
// "files changed" step: its header ("All Work" and Done, which goes back to
// the uncommitted changes; "14 files changed" with "5 of 14 viewed" at its
// row's end; "3 commits and uncommitted changes" under it; and a thin bar
// in the accent);
// its files, each led by its viewed mark, in the same AppKit table as
// Uncommitted's; and the selected file's diff from the merge base, its
// header with Mark Viewed. `AllWorkModel` holds the files, the marks, and
// the diff. The list is for reading: no checkboxes, no discard, no staging,
// and no composer.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

// MARK: - The header

/// What All Work's header shows.
nonisolated public struct AllWorkHeaderContent: Sendable, Equatable {
    /// "14 files changed", or "3 of 14 files changed" while the search hides
    /// some.
    public var title: String
    /// "3 commits and uncommitted changes".
    public var summary: String
    /// "Compared with main".
    public var baseHelp: String?
    /// "5 of 14 viewed".
    public var viewed: String
    /// How much has been viewed, 0 to 1.
    public var progress: Double

    public init(title: String, summary: String, baseHelp: String? = nil, viewed: String, progress: Double) {
        self.title = title
        self.summary = summary
        self.baseHelp = baseHelp
        self.viewed = viewed
        self.progress = progress
    }

    /// What the work is, in plain words: "3 commits and uncommitted
    /// changes", "1 commit", "Uncommitted changes" (numbers in the user's
    /// format).
    public static func summary(commitCount: Int, hasUncommitted: Bool, numberFormat: NumberFormat) -> String {
        let commits = "\(formatCount(commitCount, numberFormat)) \(commitCount == 1 ? "commit" : "commits")"
        switch (commitCount > 0, hasUncommitted) {
        case (true, true): return "\(commits) and uncommitted changes"
        case (true, false): return commits
        case (false, true): return "Uncommitted changes"
        case (false, false): return "No changes"
        }
    }

    /// "5 of 14 viewed" (numbers in the user's format).
    public static func viewed(_ count: Int, of total: Int, numberFormat: NumberFormat) -> String {
        "\(formatCount(count, numberFormat)) of \(formatCount(total, numberFormat)) viewed"
    }

    @MainActor
    public static func make(_ repository: RepositoryModel, numberFormat: NumberFormat) -> AllWorkHeaderContent {
        let allWork = repository.allWork
        let total = allWork.files.count
        let viewedCount = allWork.viewedCount
        return AllWorkHeaderContent(
            title: ChangesHeaderContent.title(fileCount: total, visibleCount: allWork.visibleFiles.count, numberFormat: numberFormat),
            summary: summary(
                commitCount: allWork.comparison?.commitCount ?? 0,
                hasUncommitted: !repository.changes.workingDirectory.files.isEmpty,
                numberFormat: numberFormat
            ),
            baseHelp: allWork.comparison.map { "Compared with \($0.baseName)" },
            viewed: viewed(viewedCount, of: total, numberFormat: numberFormat),
            progress: total > 0 ? Double(viewedCount) / Double(total) : 0
        )
    }
}

/// All Work's header: its name and Done, the title and how many are
/// viewed, the summary, then the viewed share as a thin bar in the accent.
struct AllWorkHeader: View {
    let content: AllWorkHeaderContent
    /// Goes back to the uncommitted changes.
    let onDone: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.AllWorkHeader.lineSpacing) {
            HStack(spacing: Metrics.insetSmall) {
                SectionLabel("All Work")
                Spacer(minLength: Metrics.insetSmall)
                Button("Done", action: onDone)
                    .buttonStyle(.quiet)
                    .controlSize(.small)
                    .fixedSize()
                    .tooltip("Back to the uncommitted changes")
            }
            titleRow
            // The sentence has the row to itself.
            Text(content.summary)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .tooltip(content.baseHelp)
            CapsuleProgressBar(value: content.progress, tint: Palette.accent)
                .padding(.top, Metrics.AllWorkHeader.barSpacing)
                .accessibilityLabel("Viewed")
        }
        .padding(.leading, FileRowMetrics.contentInset)
        .padding(.trailing, FileRowMetrics.contentInset)
        .padding(.vertical, Metrics.ChangesHeader.verticalPadding)
        .frame(minHeight: Metrics.PaneHeader.height)
    }

    /// The title, and how many are viewed at the row's trailing edge.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            title
                .layoutPriority(1)
            Spacer(minLength: Metrics.insetSmall)
            viewed
        }
    }

    /// "5 of 14 viewed".
    private var viewed: some View {
        Text(content.viewed)
            .font(Typography.secondary)
            .foregroundStyle(.text2)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(motion.animates ? .numericText() : .identity)
            .motion(Motion.kindChange, value: content.viewed)
    }

    private var title: some View {
        Text(content.title)
            .font(Font(ChangesHeader.titleFont as CTFont))
            .foregroundStyle(.text)
            .lineLimit(1)
            .contentTransition(motion.animates ? .numericText() : .identity)
            .motion(Motion.kindChange, value: content.title)
    }
}

extension Metrics {
    /// All Work's header.
    public enum AllWorkHeader {
        /// Between the title's line, the summary's, and the bar.
        public static let lineSpacing: CGFloat = 4
        /// Above the bar, besides the line spacing.
        public static let barSpacing: CGFloat = 3
    }
}

// MARK: - The files

/// All Work's files in Changes' table: each with its viewed mark, status,
/// name with a dot when it also has uncommitted changes, folder, and
/// its counts. One file is selected at a time; Space toggles its mark and
/// Return opens it in the editor.
struct AllWorkList: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let allWork = repository.allWork
        FileTable(
            files: .allWork(Self.rows(repository, numberFormat: context.app.preferences.numberFormat)),
            selectedIDs: allWork.selectedFileID.map { [$0] } ?? [],
            allowsMultipleSelection: false,
            tableLabel: "All work on the branch",
            scope: FileTableScope(repository: ObjectIdentifier(repository), filter: repository.changes.filter, source: "all work"),
            actions: FileTableActions(
                select: { ids in allWork.select(ids.first) },
                setViewed: { id, viewed in
                    if let file = allWork.files.first(where: { JSCompat.strictEquals($0.id, id) }) {
                        allWork.setViewed(file, viewed)
                    }
                },
                toggle: { ids in
                    for file in allWork.files where ids.contains(where: { JSCompat.strictEquals($0, file.id) }) {
                        allWork.setViewed(file, !allWork.isViewed(file))
                    }
                },
                open: { ids in
                    guard let id = ids.first, let file = allWork.files.first(where: { JSCompat.strictEquals($0.id, id) }),
                          file.change.status.kind != .deleted
                    else {
                        return
                    }
                    context.actions.perform(.openInEditor(path: POSIXPath.join(repository.record.path, file.path)))
                },
                copy: { ids in
                    let paths = allWork.files.filter { file in ids.contains { JSCompat.strictEquals($0, file.id) } }.map(\.path)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                }
            )
        )
    }

    /// The rows for the files the search shows.
    static func rows(_ repository: RepositoryModel, numberFormat: NumberFormat) -> [FileRowContent] {
        let allWork = repository.allWork
        let uncommitted = allWork.uncommittedPaths
        return allWork.visibleFiles.map { file in
            FileRowContent(
                allWork: file,
                viewed: allWork.isViewed(file),
                isUncommitted: allWork.isUncommitted(file, in: uncommitted),
                lineCount: allWork.lineCount(file),
                numberFormat: numberFormat
            )
        }
    }
}

// MARK: - The diff

/// The selected file's diff, from the merge base to the working tree, with
/// Mark Viewed in its header; else a note.
struct AllWorkDetail: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let allWork = repository.allWork
        if let file = allWork.selectedFile {
            DiffContainer(
                allWork.diff,
                file: DiffFileInfo(workingTree: file.change),
                context: .changes,
                headerAccessory: AnyView(
                    MarkViewedButton(isViewed: allWork.isViewed(file)) {
                        context.actions.perform(.markViewed)
                    }
                )
            )
        } else if allWork.files.isEmpty, let comparison = allWork.comparison {
            PlaceholderNote("No changes since \(comparison.baseName)")
        } else {
            PlaceholderNote("Select a file to see its changes")
        }
    }
}

/// The diff header's Mark Viewed: a small quiet button with its key cap.
struct MarkViewedButton: View {
    let isViewed: Bool
    let action: () -> Void

    var body: some View {
        let title = isViewed ? "Mark Not Viewed" : "Mark Viewed"
        Button(action: action) {
            HStack(spacing: Metrics.insetSmall) {
                Text(title)
                if let keys = ActionKind.markViewed.shortcut?.symbols {
                    KeyCap(keys)
                }
            }
        }
        .buttonStyle(.quiet)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

// The Changes list's header: the include-all checkbox over the rows'
// checkboxes, the title in plain words ("3 files changed"), a pill in the
// accent that says how many go into the commit, and the filter options;
// "No changes" over an empty list.
// `ChangesModel.visibleIncludeAll` decides the checkbox. As files change or
// are included, the title's and the pill's counts roll over 0.2 s; the
// filter's changes show at once.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// What the header shows.
nonisolated public struct ChangesHeaderContent: Sendable, Equatable {
    /// "3 files changed", or "2 of 5 files changed" while the filter hides
    /// some.
    public var title: String
    /// "All in the commit", "2 in the commit": the files the next commit
    /// includes, in full or in part, shown or not; empty without changes.
    public var included: String
    /// How many files the next commit includes, for the pill's color.
    public var includedCount: Int
    /// The include-all checkbox: every file shown included (true), none
    /// (false), or some (nil).
    public var includeAll: Bool?
    public var isIncludeAllEnabled: Bool
    public var filter: FilterMenuContent
    /// Every changed file, shown or not: the title's count rolls as it
    /// changes, and changes at once with the filter.
    public var fileCount: Int
    /// The repository the header is for: its checkbox animates only within
    /// one (choosing another repository is instant).
    public var repository: ObjectIdentifier?

    public init(
        title: String,
        included: String = "",
        includedCount: Int = 0,
        includeAll: Bool?,
        isIncludeAllEnabled: Bool,
        filter: FilterMenuContent,
        fileCount: Int = 0,
        repository: ObjectIdentifier? = nil
    ) {
        self.title = title
        self.included = included
        self.includedCount = includedCount
        self.includeAll = includeAll
        self.isIncludeAllEnabled = isIncludeAllEnabled
        self.filter = filter
        self.fileCount = fileCount
        self.repository = repository
    }

    /// The title: "No changes", "1 file changed", "3 files changed", "2 of
    /// 5 files changed" (numbers in the user's format).
    public static func title(fileCount: Int, visibleCount: Int, numberFormat: NumberFormat) -> String {
        guard fileCount > 0 else {
            return "No changes"
        }
        let files = "\(fileCount == 1 ? "file" : "files") changed"
        guard visibleCount != fileCount else {
            return "\(formatNumber(Double(fileCount), numberFormat)) \(files)"
        }
        return "\(formatNumber(Double(visibleCount), numberFormat)) of \(formatNumber(Double(fileCount), numberFormat)) \(files)"
    }

    /// What goes into the commit: "All in the commit", "None in the
    /// commit", "6 in the commit"; for one file, "In the commit" or "Not in
    /// the commit" (numbers in the user's format).
    public static func included(count: Int, of total: Int, numberFormat: NumberFormat) -> String {
        if total == 1 {
            return count == 1 ? "In the commit" : "Not in the commit"
        }
        if count == 0 {
            return "None in the commit"
        }
        if count == total {
            return "All in the commit"
        }
        return "\(formatNumber(Double(count), numberFormat)) in the commit"
    }

    /// How VoiceOver reads the pill: "3 of 7 files go into the commit".
    public var includedAccessibilityLabel: String {
        let files = fileCount == 1 ? "file goes" : "files go"
        return "\(includedCount) of \(fileCount) \(files) into the commit"
    }
}

extension ChangesHeaderContent {
    /// The header for a repository's changes. The checkbox can't change
    /// without files it can include, while a commit runs, or while a rebase
    /// waits on conflicts.
    @MainActor
    public static func make(_ repository: RepositoryModel, numberFormat: NumberFormat) -> ChangesHeaderContent {
        let changes = repository.changes
        let files = changes.workingDirectory.files
        let isCommitting = repository.commit.isCommitting
        var isRebaseConflicts = false
        if case .rebase? = repository.operations.conflictState {
            isRebaseConflicts = true
        }
        let includedCount = files.count(where: \.isIncludedInCommit)
        return ChangesHeaderContent(
            title: title(fileCount: files.count, visibleCount: changes.visibleFiles.count, numberFormat: numberFormat),
            included: files.isEmpty ? "" : included(count: includedCount, of: files.count, numberFormat: numberFormat),
            includedCount: includedCount,
            // Nothing to include: the box is empty.
            includeAll: files.isEmpty ? false : changes.visibleIncludeAll,
            isIncludeAllEnabled: files.contains { !$0.isUncommittableSubmodule } && !isCommitting && !isRebaseConflicts,
            filter: FilterMenuContent(filter: changes.filter, visibleFiles: changes.visibleFiles, numberFormat: numberFormat),
            fileCount: files.count,
            repository: ObjectIdentifier(repository)
        )
    }
}

/// The header above the changed files, as high as the diff's. The
/// checkbox's title is the header's: a click on the title toggles it, as a click on a checkbox's own title does.
public struct ChangesHeader: View {
    private let content: ChangesHeaderContent
    private let onIncludeAll: (Bool) -> Void
    private let onFilterChange: (FileListFilter) -> Void
    private let onClearFilters: () -> Void
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - onIncludeAll: Includes (true) or excludes every file shown.
    ///   - onFilterChange: Applies the filter options.
    ///   - onClearFilters: Clears the options and the toolbar's text.
    public init(
        _ content: ChangesHeaderContent,
        onIncludeAll: @escaping (Bool) -> Void = { _ in },
        onFilterChange: @escaping (FileListFilter) -> Void = { _ in },
        onClearFilters: @escaping () -> Void = {}
    ) {
        self.content = content
        self.onIncludeAll = onIncludeAll
        self.onFilterChange = onFilterChange
        self.onClearFilters = onClearFilters
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.ChangesHeader.pillSpacing) {
            titleRow
            if !content.included.isEmpty {
                // Under the title, as its line: the pill shows in full, its
                // text giving way at its end in the narrowest column.
                includedPill
                    .padding(.leading, CheckboxDrawing.size + Metrics.Checkbox.titleSpacing)
                    .padding(.trailing, Metrics.insetSmall)
            }
        }
        .padding(.leading, FileRowMetrics.contentInset)
        .padding(.trailing, Metrics.insetSmall)
        .padding(.vertical, Metrics.ChangesHeader.verticalPadding)
        .frame(minHeight: Metrics.PaneHeader.height)
    }

    /// The include-all checkbox, titled with the header's title, then the
    /// filter options.
    private var titleRow: some View {
        HStack(spacing: Metrics.insetSmall) {
            includeAll
                .layoutPriority(1)
            Spacer(minLength: 0)
            FilterMenu(content.filter, onChange: onFilterChange, onClear: onClearFilters)
        }
    }

    /// The include-all checkbox, drawing the header's title.
    private var includeAll: some View {
        InclusionCheckbox(
            value: content.includeAll,
            isEnabled: content.isIncludeAllEnabled,
            title: content.title,
            titleFont: Self.titleFont,
            drawsTitle: false,
            scope: content.repository,
            onChange: onIncludeAll
        )
        .overlay {
            ChangesHeaderTitle(title: content.title, fileCount: content.fileCount)
        }
        .disabled(!content.isIncludeAllEnabled)
        .accessibilityLabel("Include all changed files")
        .accessibilityValue(content.title)
    }

    /// How many go into the commit, in the accent; a neutral pill while
    /// none do. Its count rolls as checkboxes and files change it (0.2 s).
    private var includedPill: some View {
        TintedPill(content.included, color: content.includedCount > 0 ? Palette.accent : Palette.text3)
            .contentTransition(motion.animates ? .numericText() : .identity)
            .motion(Motion.kindChange, value: content.included)
            .accessibilityLabel(content.includedAccessibilityLabel)
    }

    /// The title's font: the pane title's, 15 and bold, over stacked
    /// cards; the row font, semibold, between hairlines.
    static var titleFont: NSFont {
        if ChangesThemeStyle.current.panes == .hairlines {
            return AppKitTypography.row(weight: .semibold)
        }
        return AppKitTypography.sans(.title3, weight: .bold)
    }
}

extension Metrics {
    /// The Changes list's header.
    public enum ChangesHeader {
        /// Between the title's line and the pill under it.
        public static let pillSpacing: CGFloat = 3
        /// Above the title and below the pill.
        public static let verticalPadding: CGFloat = 9
    }
}

/// The header's title, drawn where the checkbox would draw its
/// title; the checkbox keeps the title for its size, its clicks, and
/// VoiceOver. A new count of files rolls over 0.2 s; the filter's changes
/// show at once, whatever moves around the title, and so does the title
/// turning off and on.
private struct ChangesHeaderTitle: View {
    let title: String
    let fileCount: Int
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motion) private var motion

    var body: some View {
        let font = ChangesHeader.titleFont
        let height = NSAttributedString(string: title, attributes: [.font: font]).size().height
        GeometryReader { proxy in
            let rect = CheckboxButton.titleRect(height: height, in: proxy.size)
            Text(title)
                .font(Font(font as CTFont))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(motion.animates ? .numericText() : .identity)
                .animation(motion.animation(Motion.kindChange), value: fileCount)
                .transaction(value: title) { $0.animation = nil }
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .offset(x: rect.minX, y: rect.minY)
                .opacity(isEnabled ? 1 : Palette.disabledOpacity)
                .transaction(value: isEnabled) { $0.animation = nil }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

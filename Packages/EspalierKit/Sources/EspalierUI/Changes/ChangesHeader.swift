// The Changes list's header: the include-all checkbox with the file count,
// and the filter options. `ChangesModel.visibleIncludeAll` decides the
// checkbox.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// What the header shows.
nonisolated public struct ChangesHeaderContent: Sendable, Equatable {
    /// "3 changed files", or "2 of 5 changed files" while the filter hides some.
    public var title: String
    /// "6 included": the files the next commit includes, in full or in
    /// part, shown or not.
    public var included: String
    /// The include-all checkbox: every file shown included (true), none
    /// (false), or some (nil).
    public var includeAll: Bool?
    public var isIncludeAllEnabled: Bool
    public var filter: FilterMenuContent
    /// Every changed file, shown or not: the title's count changes with
    /// it (animated), and with the filter (at once, as the user types).
    public var fileCount: Int
    /// The repository the header is for: its checkbox and count animate
    /// only within one (choosing another repository is instant).
    public var repository: ObjectIdentifier?

    public init(
        title: String,
        included: String = "",
        includeAll: Bool?,
        isIncludeAllEnabled: Bool,
        filter: FilterMenuContent,
        fileCount: Int = 0,
        repository: ObjectIdentifier? = nil
    ) {
        self.title = title
        self.included = included
        self.includeAll = includeAll
        self.isIncludeAllEnabled = isIncludeAllEnabled
        self.filter = filter
        self.fileCount = fileCount
        self.repository = repository
    }

    /// The count line: "1 changed file", "3 changed files", "2 of 5
    /// changed files" (numbers in the user's format).
    public static func title(fileCount: Int, visibleCount: Int, numberFormat: NumberFormat) -> String {
        let total = "\(formatNumber(Double(fileCount), numberFormat)) changed \(fileCount == 1 ? "file" : "files")"
        guard visibleCount != fileCount else {
            return total
        }
        return "\(formatNumber(Double(visibleCount), numberFormat)) of \(total)"
    }

    /// "6 included" (numbers in the user's format).
    public static func included(count: Int, numberFormat: NumberFormat) -> String {
        "\(formatNumber(Double(count), numberFormat)) included"
    }
}

extension ChangesHeaderContent {
    /// The header for a repository's changes. The checkbox can't change
    /// while a commit runs or a rebase waits on conflicts.
    @MainActor
    public static func make(_ repository: RepositoryModel, numberFormat: NumberFormat) -> ChangesHeaderContent {
        let changes = repository.changes
        let files = changes.workingDirectory.files
        let isCommitting = repository.localOperation?.kind == .commit
        var isRebaseConflicts = false
        if case .rebase? = repository.operations.conflictState {
            isRebaseConflicts = true
        }
        let includedCount = files.count { $0.selection.getSelectionType() != .none }
        return ChangesHeaderContent(
            title: title(fileCount: files.count, visibleCount: changes.visibleFiles.count, numberFormat: numberFormat),
            included: included(count: includedCount, numberFormat: numberFormat),
            includeAll: changes.visibleIncludeAll,
            isIncludeAllEnabled: !files.isEmpty && !isCommitting && !isRebaseConflicts,
            filter: FilterMenuContent(filter: changes.filter, visibleFiles: changes.visibleFiles),
            fileCount: files.count,
            repository: ObjectIdentifier(repository)
        )
    }
}

/// The header above the changed files.
public struct ChangesHeader: View {
    private let content: ChangesHeaderContent
    private let onIncludeAll: (Bool) -> Void
    private let onFilterChange: (FileListFilter) -> Void
    private let onClearFilters: () -> Void

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
        HStack(spacing: FileRowMetrics.spacing) {
            InclusionCheckbox(
                value: content.includeAll,
                isEnabled: content.isIncludeAllEnabled,
                title: content.title,
                titleFont: Self.titleFont,
                titleCount: content.fileCount,
                scope: content.repository,
                onChange: onIncludeAll
            )
            .accessibilityLabel("Include all changed files")
            .accessibilityValue(content.title)
            .layoutPriority(1)
            if !content.included.isEmpty {
                // The count rolls as checkboxes change it (0.2 s).
                Text(content.included)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .motion(Motion.kindChange, value: content.included)
            }
            Spacer(minLength: Metrics.insetSmall)
            FilterMenu(content.filter, onChange: onFilterChange, onClear: onClearFilters)
        }
        .padding(.leading, FileRowMetrics.contentInset)
        .padding(.trailing, Metrics.insetSmall)
        .frame(height: ChangesHeader.height)
    }

    /// The header row's height: a compact header row atop each column.
    static let height: CGFloat = 40

    /// The count's font: the row font, semibold.
    static var titleFont: NSFont {
        .systemFont(ofSize: AppKitTypography.row.pointSize, weight: .semibold)
    }
}

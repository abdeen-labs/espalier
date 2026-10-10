// The Changes list's filter options. The text part of the filter is the
// toolbar's search field; this menu holds the options: the five options with
// their counts over the files shown, and Clear Filters. `FileListFilter`
// applies them.

import EspalierCore
import GitKit
import SwiftUI

/// The filter options and how many of the files shown each would keep.
nonisolated public struct FilterMenuContent: Sendable, Equatable {
    /// The filter, its text included.
    public var filter: FileListFilter
    public var includedCount: Int
    public var excludedCount: Int
    public var newCount: Int
    public var modifiedCount: Int
    public var deletedCount: Int

    public init(
        filter: FileListFilter = FileListFilter(),
        includedCount: Int = 0,
        excludedCount: Int = 0,
        newCount: Int = 0,
        modifiedCount: Int = 0,
        deletedCount: Int = 0
    ) {
        self.filter = filter
        self.includedCount = includedCount
        self.excludedCount = excludedCount
        self.newCount = newCount
        self.modifiedCount = modifiedCount
        self.deletedCount = deletedCount
    }

    /// The counts over `visibleFiles`, the files the list shows.
    public init(filter: FileListFilter, visibleFiles: [WorkingDirectoryFileChange]) {
        self.init(filter: filter)
        for file in visibleFiles {
            if file.isIncludedInCommit() {
                includedCount += 1
            }
            if file.isExcludedFromCommit() {
                excludedCount += 1
            }
            switch file.status.kind {
            case .new, .untracked: newCount += 1
            case .modified: modifiedCount += 1
            case .deleted: deletedCount += 1
            case .renamed, .copied, .conflicted: break
            }
        }
    }

    /// How many options are on (the text doesn't count).
    public var activeOptionCount: Int {
        filter.activeOptionCount
    }

    /// The button's tooltip.
    public var help: String {
        activeOptionCount > 0 ? "Filter Options (\(activeOptionCount) Applied)" : "Filter Options"
    }

    /// The button's symbol: plain, and filled in a circle while options
    /// are on.
    public var systemImage: String {
        activeOptionCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
    }

    /// The menu's options, in order, with their titles.
    public var options: [FilterOption] {
        [
            FilterOption(title: "Included in Commit (\(includedCount))", keyPath: \.includedInCommit),
            FilterOption(title: "Excluded from Commit (\(excludedCount))", keyPath: \.excludedFromCommit),
            FilterOption(title: "New Files (\(newCount))", keyPath: \.newFiles),
            FilterOption(title: "Modified Files (\(modifiedCount))", keyPath: \.modifiedFiles),
            FilterOption(title: "Deleted Files (\(deletedCount))", keyPath: \.deletedFiles),
        ]
    }
}

/// One option of the filter menu.
nonisolated public struct FilterOption: Sendable, Identifiable {
    public let title: String
    public let keyPath: WritableKeyPath<FileListFilter, Bool> & Sendable

    public var id: String {
        title
    }
}

/// The filter options button and its menu.
public struct FilterMenu: View {
    private let content: FilterMenuContent
    private let onChange: (FileListFilter) -> Void
    private let onClear: () -> Void

    /// - Parameters:
    ///   - onChange: Applies the filter with an option turned on or off.
    ///   - onClear: Clears every option and the toolbar's text.
    public init(_ content: FilterMenuContent, onChange: @escaping (FileListFilter) -> Void, onClear: @escaping () -> Void) {
        self.content = content
        self.onChange = onChange
        self.onClear = onClear
    }

    public var body: some View {
        Menu {
            ForEach(content.options) { option in
                Toggle(option.title, isOn: Binding(
                    get: { content.filter[keyPath: option.keyPath] },
                    set: { isOn in
                        var filter = content.filter
                        filter[keyPath: option.keyPath] = isOn
                        onChange(filter)
                    }
                ))
            }
            if content.filter.hasActiveFilters {
                Divider()
                Button("Clear Filters", action: onClear)
            }
        } label: {
            Label {
                Text("Filter Options")
            } icon: {
                Image(systemName: content.systemImage)
                    .font(.system(size: content.activeOptionCount > 0 ? 15 : 13))
                    .foregroundStyle(content.activeOptionCount > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.text3))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.icon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(content.help)
        .accessibilityLabel(content.help)
    }
}

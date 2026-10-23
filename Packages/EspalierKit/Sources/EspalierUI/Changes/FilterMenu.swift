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
    /// The format the counts show in.
    public var numberFormat: NumberFormat

    public init(
        filter: FileListFilter = FileListFilter(),
        includedCount: Int = 0,
        excludedCount: Int = 0,
        newCount: Int = 0,
        modifiedCount: Int = 0,
        deletedCount: Int = 0,
        numberFormat: NumberFormat = defaultNumberFormat
    ) {
        self.filter = filter
        self.includedCount = includedCount
        self.excludedCount = excludedCount
        self.newCount = newCount
        self.modifiedCount = modifiedCount
        self.deletedCount = deletedCount
        self.numberFormat = numberFormat
    }

    /// The counts over `visibleFiles`, the files the list shows, in
    /// `numberFormat`.
    public init(filter: FileListFilter, visibleFiles: [WorkingDirectoryFileChange], numberFormat: NumberFormat) {
        self.init(filter: filter, numberFormat: numberFormat)
        for file in visibleFiles {
            if file.isExcludedFromCommit() {
                excludedCount += 1
            } else {
                includedCount += 1
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
        activeOptionCount > 0 ? "Filter Options (\(formatCount(activeOptionCount, numberFormat)) Applied)" : "Filter Options"
    }

    /// The button's symbol: in a circle, filled while options are on (one
    /// size either way).
    public var systemImage: String {
        activeOptionCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    /// The menu's options, in order, with their titles.
    public var options: [FilterOption] {
        [
            FilterOption(title: "Included in Commit (\(formatCount(includedCount, numberFormat)))", keyPath: \.includedInCommit),
            FilterOption(title: "Excluded from Commit (\(formatCount(excludedCount, numberFormat)))", keyPath: \.excludedFromCommit),
            FilterOption(title: "New Files (\(formatCount(newCount, numberFormat)))", keyPath: \.newFiles),
            FilterOption(title: "Modified Files (\(formatCount(modifiedCount, numberFormat)))", keyPath: \.modifiedFiles),
            FilterOption(title: "Deleted Files (\(formatCount(deletedCount, numberFormat)))", keyPath: \.deletedFiles),
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
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - onChange: Applies the filter with an option turned on or off.
    ///   - onClear: Clears every option and the toolbar's text.
    public init(_ content: FilterMenuContent, onChange: @escaping (FileListFilter) -> Void, onClear: @escaping () -> Void) {
        self.content = content
        self.onChange = onChange
        self.onClear = onClear
    }

    public var body: some View {
        PullDownButton(content.help) { [content, onChange, onClear] in
            for option in content.options {
                let isOn = content.filter[keyPath: option.keyPath]
                MenuToggle(option.title, isOn: isOn) {
                    var filter = content.filter
                    filter[keyPath: option.keyPath] = !isOn
                    onChange(filter)
                }
            }
            if content.filter.hasActiveFilters {
                MenuDivider()
                MenuAction("Clear Filters", action: onClear)
            }
        } label: {
            // While options are on, the symbol fills in the accent (a
            // symbol replace).
            Label {
                Text("Filter Options")
            } icon: {
                Image(systemName: content.systemImage)
                    .foregroundStyle(content.activeOptionCount > 0 ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.text2))
                    .contentTransition(motion.animates ? .symbolEffect(.replace) : .identity)
                    .motion(Motion.leave, value: content.activeOptionCount > 0)
            }
        }
        .buttonStyle(.icon)
        .fixedSize()
        .tooltip(content.help)
    }
}

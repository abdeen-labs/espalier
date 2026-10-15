// A repository's row in the repository popover: the alias or name (the
// selected repository's semibold), the owner where the name is ambiguous,
// the status indicators with their tooltips, the hover tooltip (full name,
// alias, path), and the cloning and missing states.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// What a repository row shows.
nonisolated struct RepositoryRowContent: Sendable, Equatable, Identifiable {
    /// The row's glyph.
    enum Icon: Sendable, Equatable {
        /// The selected repository: its badge, and its title semibold.
        case current
        case other
        /// The folder is gone, or git won't work in it.
        case missing
        /// Being cloned: a ring, determinate once git reports progress.
        case cloning(progress: Double)
    }

    let id: RepositoryListEntryID
    /// The alias, or the name.
    var title: String
    /// Where the title is ambiguous: the owner (GitHub), or the folder it's
    /// in.
    var subtitle: String?
    var icon: Icon
    /// Changed files, and commits ahead of and behind the upstream: shown
    /// when "Show status icons in the repository list" is on.
    var changedFileCount = 0
    var ahead = 0
    var behind = 0
    var showsStatus = false
    /// The repository's full name (owner/name, or its name), its alias, and
    /// its path, for the tooltip.
    var fullName: String
    var alias: String?
    var path: String

    /// The hover tooltip: the full name, the alias in parentheses, then the
    /// path.
    var tooltip: String {
        var text = fullName
        if let alias {
            text += " (\(alias))"
        }
        return "\(text)\n\(path)"
    }

    /// The tooltip for the ahead and behind arrows: "The currently checked
    /// out branch is 2 commits behind and 1 commit ahead of its tracked
    /// branch.", the counts in `numberFormat`.
    func aheadBehindTooltip(_ numberFormat: NumberFormat) -> String? {
        guard showsStatus, ahead > 0 || behind > 0 else {
            return nil
        }
        func commits(_ count: Int) -> String {
            count == 1 ? "1 commit" : "\(formatCount(count, numberFormat)) commits"
        }
        var text = "The currently checked out branch is"
        if behind > 0 {
            text += " \(commits(behind)) behind "
        }
        if behind > 0, ahead > 0 {
            text += "and"
        }
        if ahead > 0 {
            text += " \(commits(ahead)) ahead of "
        }
        return text + "its tracked branch."
    }

    /// The tooltip for the changes indicator.
    static let changesTooltip = "There are uncommitted changes in this repository"

    /// What VoiceOver reads, the counts in `numberFormat`.
    func accessibilityLabel(_ numberFormat: NumberFormat) -> String {
        var parts = [title]
        if let subtitle {
            parts.append(subtitle)
        }
        switch icon {
        case .missing: parts.append("Missing")
        case .cloning: parts.append("Cloning")
        case .current, .other: break
        }
        if showsStatus {
            if changedFileCount > 0 {
                parts.append(changedFileCount == 1 ? "1 changed file" : "\(formatCount(changedFileCount, numberFormat)) changed files")
            }
            if ahead > 0 {
                parts.append("\(formatCount(ahead, numberFormat)) ahead")
            }
            if behind > 0 {
                parts.append("\(formatCount(behind, numberFormat)) behind")
            }
        }
        return parts.joined(separator: ", ")
    }
}

extension RepositoryRowContent {
    /// The row for a list item.
    @MainActor
    init(_ item: RepositoryListItem, selection: AppSelection?, availability: (RepositoryID) -> RepositoryAvailability?, showsStatus: Bool, disambiguates: Bool) {
        // The item's texts are its title and, for a repository, its full
        // name (owner/name, or its name).
        let title = item.text.first ?? item.repository.displayTitle
        switch item.repository {
        case .repository(let record):
            let isMissing: Bool
            switch availability(record.id) {
            case .missing?, .unsafe?: isMissing = true
            default: isMissing = record.isMissing
            }
            self.init(
                id: item.id,
                title: title,
                subtitle: disambiguates ? Self.disambiguation(for: record) : nil,
                icon: isMissing ? .missing : (selection == .repository(record.id) ? .current : .other),
                changedFileCount: item.changedFilesCount,
                ahead: item.aheadBehind?.ahead ?? 0,
                behind: item.aheadBehind?.behind ?? 0,
                showsStatus: showsStatus && !isMissing,
                fullName: item.text.count > 1 ? item.text[1] : title,
                alias: record.alias,
                path: record.path
            )
        case .clone(let clone):
            self.init(
                id: item.id,
                title: title,
                subtitle: nil,
                icon: .cloning(progress: clone.progress?.value ?? 0),
                fullName: title,
                path: clone.path
            )
        }
    }

    /// What tells two repositories with one title apart: the owner of a
    /// GitHub repository, else the folder the repository is in.
    static func disambiguation(for record: RepositoryRecord) -> String {
        if let owner = record.gitHubRepository?.owner.login {
            return owner
        }
        return abbreviatedPath(POSIXPath.dirname(record.path))
    }

    /// `path` with the home folder as `~`.
    static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if JSCompat.strictEquals(path, home) {
            return "~"
        }
        if JSCompat.startsWith(path, home + "/") {
            return "~" + JSCompat.dropFirst(path, home.utf16.count)
        }
        return path
    }
}

/// A repository row: the glyph, the title (with the owner when ambiguous),
/// and the status indicators.
struct RepositoryRow: View {
    let content: RepositoryRowContent
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            RepositoryRowIcon(icon: content.icon, title: content.title)
            VStack(alignment: .leading, spacing: 0) {
                Text(content.title)
                    .font(content.icon == .current ? Typography.row.weight(.semibold) : Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(Typography.subheadline)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Metrics.grid)
            RepositoryStatusIndicators(content: content)
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel(numberFormat))
    }
}

/// The row's glyph.
struct RepositoryRowIcon: View {
    let icon: RepositoryRowContent.Icon
    /// The repository's title, for its badge's letter and color.
    var title = ""

    var body: some View {
        Group {
            switch icon {
            case .current, .other:
                RepositoryBadge(title: title)
            case .missing:
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.text3)
            case .cloning(let progress):
                // It turns until git reports how far it has got.
                ArcProgress(.mini, value: progress > 0 ? progress : nil)
            }
        }
        .frame(width: Metrics.Sidebar.badgeSize, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// The changed files count and the ahead and behind counts, with their
/// tooltips.
struct RepositoryStatusIndicators: View {
    let content: RepositoryRowContent
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        if content.showsStatus {
            HStack(spacing: Metrics.grid) {
                if content.changedFileCount > 0 {
                    Text(verbatim: content.changedFileCount > 999 ? "999+" : formatCount(content.changedFileCount, numberFormat))
                        .font(Typography.tinyCount)
                        .foregroundStyle(.text2)
                        .padding(.horizontal, Metrics.grid + 1)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .circular).fill(.field))
                        .tooltip(RepositoryRowContent.changesTooltip)
                }
                if let tooltip = content.aheadBehindTooltip(numberFormat) {
                    HStack(spacing: Metrics.grid) {
                        if content.ahead > 0 {
                            Text(verbatim: "↑\(formatCount(content.ahead, numberFormat))")
                                .font(Typography.aheadCount)
                                .foregroundStyle(.aheadText)
                        }
                        if content.behind > 0 {
                            Text(verbatim: "↓\(formatCount(content.behind, numberFormat))")
                                .font(Typography.secondaryCount)
                                .foregroundStyle(.text3)
                        }
                    }
                    .tooltip(tooltip)
                }
            }
        }
    }
}

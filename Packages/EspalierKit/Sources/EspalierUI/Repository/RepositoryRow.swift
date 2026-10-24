// A repository's row in the repository popover: the alias or name (the
// selected repository's semibold) with a lock after a private repository's
// and a branch after a fork's, the owner where the name is ambiguous, the
// status indicators with their tooltips, and the hover tooltip (full name,
// alias, path). The glyph column under the group's mark is empty but for a
// missing repository's glyph, a clone's ring, and in Recent, where owners
// mix, the owner's avatar.

import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// What a repository row shows.
nonisolated struct RepositoryRowContent: Sendable, Equatable, Identifiable {
    /// What the repository is: the mark after its name, or the glyph of a
    /// missing or cloning one.
    enum Icon: Sendable, Equatable {
        /// A public GitHub repository.
        case repository
        /// A private GitHub repository.
        case `private`
        /// A fork of a GitHub repository.
        case fork
        /// A repository that isn't on GitHub.
        case local
        /// The folder is gone, or git won't work in it.
        case missing
        /// Being cloned: a ring, determinate once git reports progress.
        case cloning(progress: Double)
    }

    let id: RepositoryListEntryID
    /// The alias, or the name.
    var title: String
    /// Where the title is ambiguous: the owner (GitHub), or the folder it's
    /// in, at the row's trailing edge.
    var subtitle: String?
    var icon: Icon
    /// In Recent, the glyph column shows where the repository is from: the
    /// owner's avatar, or a folder for one not on GitHub (`owner` nil).
    var showsOwner = false
    var owner: AvatarUser?
    /// The selected repository: its title semibold.
    var isCurrent = false
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
        case .private: parts.append("Private")
        case .fork: parts.append("Fork")
        case .missing: parts.append("Missing")
        case .cloning: parts.append("Cloning")
        case .repository, .local: break
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
    ///
    /// - Parameter showsOwner: A row in Recent: its owner's avatar leads it.
    @MainActor
    init(_ item: RepositoryListItem, selection: AppSelection?, availability: (RepositoryID) -> RepositoryAvailability?, showsStatus: Bool, disambiguates: Bool, showsOwner: Bool = false) {
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
                icon: isMissing ? .missing : Self.icon(for: record),
                showsOwner: showsOwner,
                owner: showsOwner ? record.gitHubRepository.map { AvatarUser(owner: $0.owner) } : nil,
                isCurrent: !isMissing && selection == .repository(record.id),
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

    /// The glyph for a repository that's there, as desktop's
    /// `iconForRepository`: private, a fork, or public on GitHub, else not
    /// on GitHub.
    static func icon(for record: RepositoryRecord) -> Icon {
        guard let gitHubRepository = record.gitHubRepository else {
            return .local
        }
        if gitHubRepository.isPrivate == true {
            return .private
        }
        return gitHubRepository.fork ? .fork : .repository
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

nonisolated extension AvatarUser {
    /// A GitHub owner's avatar: GitHub.com's by the owner's ID, or by login
    /// until the API has given the ID; an Enterprise owner's monogram.
    init(owner: Owner) {
        let avatarURL: String? = if isDotCom(owner.endpoint) {
            owner.id.map { "https://avatars.githubusercontent.com/u/\($0)" } ?? "https://avatars.githubusercontent.com/\(owner.login)"
        } else {
            nil
        }
        self.init(email: "", avatarURL: avatarURL, name: owner.login, endpoint: owner.endpoint)
    }
}

/// A repository row: the glyph column, the title and its mark, the owner
/// when ambiguous, and the status indicators.
struct RepositoryRow: View {
    let content: RepositoryRowContent
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            RepositoryRowGlyph(content: content)
            HStack(spacing: Metrics.grid + 1) {
                Text(content.title)
                    .font(content.isCurrent ? Typography.row.weight(.semibold) : Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                RepositoryKindMark(icon: content.icon)
            }
            // The name wins over the owner when the row is narrow.
            .layoutPriority(1)
            Spacer(minLength: Metrics.grid)
            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            RepositoryStatusIndicators(content: content)
        }
        .tooltip(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel(numberFormat))
    }
}

/// The row's glyph column, under its group's mark: a missing repository's
/// glyph, a clone's ring, in Recent the owner's avatar (a folder for a
/// repository not on GitHub), else empty.
struct RepositoryRowGlyph: View {
    let content: RepositoryRowContent

    var body: some View {
        // A stack, not a group, so an empty column keeps its width.
        ZStack {
            switch content.icon {
            case .missing:
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.text3)
            case .cloning(let progress):
                // It turns until git reports how far it has got.
                ArcProgress(.mini, value: progress > 0 ? progress : nil)
            case .repository, .private, .fork, .local:
                if content.showsOwner {
                    if let owner = content.owner {
                        Avatar(owner, size: Metrics.RepositoryPopover.rowAvatarSize)
                    } else {
                        Image(systemName: "folder")
                            .foregroundStyle(.text3)
                    }
                }
            }
        }
        .frame(width: Metrics.Sidebar.glyphSize, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// The mark after a repository's name: a lock for a private repository, a
/// branch for a fork.
struct RepositoryKindMark: View {
    let icon: RepositoryRowContent.Icon

    var body: some View {
        switch icon {
        case .private:
            mark("lock.fill")
        case .fork:
            mark("arrow.trianglehead.branch")
        case .repository, .local, .missing, .cloning:
            EmptyView()
        }
    }

    private func mark(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(Typography.subheadline)
            .imageScale(.small)
            .foregroundStyle(.text3)
            .accessibilityHidden(true)
    }
}

/// The changed files count and the ahead and behind counts, with their
/// tooltips. A count that changes while the list shows rolls to its new
/// value over 0.2 s.
struct RepositoryStatusIndicators: View {
    let content: RepositoryRowContent
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    var body: some View {
        if content.showsStatus {
            HStack(spacing: Metrics.grid) {
                if content.changedFileCount > 0 {
                    Text(verbatim: content.changedFileCount > 999 ? "999+" : formatCount(content.changedFileCount, numberFormat))
                        .font(Typography.tinyCount)
                        .foregroundStyle(.text2)
                        .contentTransition(motion.animates ? .numericText() : .identity)
                        .padding(.horizontal, Metrics.grid + 1)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .circular).fill(.field))
                        .motion(Motion.kindChange, value: content.changedFileCount)
                        .tooltip(RepositoryRowContent.changesTooltip)
                }
                if let tooltip = content.aheadBehindTooltip(numberFormat) {
                    HStack(spacing: Metrics.grid) {
                        if content.ahead > 0 {
                            Text(verbatim: "↑\(formatCount(content.ahead, numberFormat))")
                                .font(Typography.aheadCount)
                                .foregroundStyle(.aheadText)
                                .contentTransition(motion.animates ? .numericText() : .identity)
                                .motion(Motion.kindChange, value: content.ahead)
                        }
                        if content.behind > 0 {
                            Text(verbatim: "↓\(formatCount(content.behind, numberFormat))")
                                .font(Typography.secondaryCount)
                                .foregroundStyle(.text3)
                                .contentTransition(motion.animates ? .numericText() : .identity)
                                .motion(Motion.kindChange, value: content.behind)
                        }
                    }
                    .tooltip(tooltip)
                }
            }
            // The counts keep one line; the owner beside them truncates.
            .fixedSize()
        }
    }
}

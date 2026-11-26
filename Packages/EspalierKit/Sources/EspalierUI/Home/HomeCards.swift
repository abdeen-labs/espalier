// Home's pieces: a card of Needs You (its head, headline with its time,
// peek, and the next step beside the pending counts), the same as a plain
// row where the theme draws plainly, In Progress's rows, and the Quiet line
// that opens into the quiet repositories, a group for each owner.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

// MARK: - A card

/// A piece of work that needs the user, as a card on the backdrop. A click
/// away from its button opens the work.
struct HomeCardView: View {
    let card: HomeCard
    /// Whether Home has the keyboard in the key window, so the focused card
    /// shows the ring.
    var showsFocusRing = true
    let actions: HomeViewActions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.insetSmall) {
                HomeRepositoryTitle(title: card.title, owner: card.owner, font: Typography.paneHeading)
                if let branch = card.branch {
                    HomeBranchView(branch: branch)
                }
                Spacer(minLength: Metrics.insetSmall)
                if card.isUnseen {
                    HomeUnseenDot()
                }
            }
            HomeHeadlineLine(card: card)
                .padding(.top, Metrics.Home.cardLineSpacing)
            HomePeekView(peek: card.peek)
                .padding(.top, Metrics.Home.cardLineSpacing)
            Spacer(minLength: Metrics.insetMedium)
            HStack(spacing: Metrics.insetSmall) {
                HomeStepButton(card: card, takeStep: actions.takeStep)
                if card.isFocused, showsFocusRing {
                    Text("Return")
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: Metrics.insetSmall)
                HomePendingCounts(card: card)
            }
        }
        .padding(Metrics.Home.cardPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.Home.cardMinHeight, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.isInPaneCard, true)
        .homeCardSurface(in: shape)
        .focusRing(card.isFocused && showsFocusRing, in: shape, outset: 0)
        .contentShape(shape)
        .onTapGesture {
            actions.open(card.id)
        }
        .contextMenuCard {
            actions.menu(card.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: card.title))
    }
}

extension View {
    /// A card on the backdrop, as the floating panes are: the pane's fill,
    /// the raised ring, and the soft shadow.
    func homeCardSurface(in shape: some InsettableShape) -> some View {
        let theme = Theme.current
        return background {
            shape
                .fill(Color(nsColor: theme.background))
                .shadow(color: Color(nsColor: theme.raisedShadow), radius: PaneCards.shadowBlur / 2, y: PaneCards.shadowOffset)
        }
        .overlay {
            shape
                .strokeBorder(Color(nsColor: theme.raisedRing), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// A piece of work that needs the user, as a plain row split from the next
/// by a hairline: the repository and the branch, then the headline and its
/// peek; the counts and the next step at the trailing edge. The focused row
/// is selected.
struct HomeCardRow: View {
    let card: HomeCard
    let actions: HomeViewActions
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        HStack(spacing: Metrics.insetMedium) {
            VStack(alignment: .leading, spacing: Metrics.grid) {
                HStack(spacing: Metrics.insetSmall) {
                    HomeRepositoryTitle(title: card.title, owner: card.owner, font: Typography.row.weight(.semibold))
                    if let branch = card.branch {
                        HomeBranchView(branch: branch)
                    }
                    if card.isUnseen {
                        HomeUnseenDot()
                    }
                }
                HStack(spacing: Metrics.Home.symbolSpacing) {
                    HomeHeadlineLine(card: card, font: Typography.secondary)
                        .layoutPriority(1)
                    if let peek = card.peek.summary(numberFormat) {
                        Text(peek)
                            .font(Typography.secondary)
                            .foregroundStyle(.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: Metrics.insetSmall)
            HomePendingCounts(card: card)
            HomeStepButton(card: card, takeStep: actions.takeStep)
                .controlSize(.small)
        }
        .padding(.vertical, Metrics.Home.plainRowPadding)
        .selectableRow(isSelected: card.isFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            actions.open(card.id)
        }
        .contextMenuCard {
            actions.menu(card.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: card.title))
    }
}

/// The repository's title, and its owner (or its folder) in tertiary text
/// where the title is ambiguous. The owner is at most
/// `Metrics.Home.ownerMaxWidth` wide and gives way first, cut at its head so
/// the folder nearest the repository stays.
struct HomeRepositoryTitle: View {
    let title: String
    let owner: String?
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.grid + 1) {
            Text(title)
                .font(font)
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if let owner {
                HomeCappedWidth(maximumWidth: Metrics.Home.ownerMaxWidth) {
                    Text(owner)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .layoutPriority(-1)
                .tooltip(owner)
            }
        }
    }
}

/// Offers its one view at most `maximumWidth` and takes the view's own
/// size, where `frame(maxWidth:)` would grow to `maximumWidth`.
struct HomeCappedWidth: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A branch as the theme labels one: a candy pill in its color, or its name
/// in the code font; a detached HEAD's short SHA in the code font.
struct HomeBranchView: View {
    let branch: HomeBranchLabel
    /// The pill's size: a card's, or a row's.
    var size: CandyPillSize = .regular

    var body: some View {
        Group {
            if branch.isDetached || HomeThemeStyle.current.branchLabel == .monospaced {
                Text(branch.text)
                    .font(Typography.sha(weight: .medium))
                    .foregroundStyle(.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                CandyPill(branch.text, color: branch.color, size: size)
            }
        }
        .tooltip(branch.text)
    }
}

/// The dot of work that changed since the user last looked.
struct HomeUnseenDot: View {
    var body: some View {
        Circle()
            .fill(.accent)
            .frame(width: Metrics.Home.unseenDot, height: Metrics.Home.unseenDot)
            .tooltip("Changed since you last looked")
            .accessibilityLabel("Changed since you last looked")
    }
}

/// The mark, the headline in semibold, then its detail and time in
/// secondary text. The time ticks once a minute.
struct HomeHeadlineLine: View {
    let card: HomeCard
    var font: Font = Typography.row
    @Environment(\.scheduler) private var scheduler
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let mark = card.headline.mark
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Home.symbolSpacing) {
            if let systemImage = mark.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: Metrics.Home.markSize, weight: .semibold))
                    .foregroundStyle(Color(espalier: mark.color))
                    .frame(width: Metrics.symbolWidth)
                    .accessibilityHidden(true)
            }
            Text(card.headline.title(numberFormat))
                .font(font.weight(.semibold))
                .foregroundStyle(.text)
                .lineLimit(1)
                .layoutPriority(1)
            // Ticks once a minute, telling time by the app's clock.
            TimelineView(.everyMinute) { _ in
                if let detail = detail(now: scheduler.now) {
                    Text(detail)
                        .font(font)
                        .foregroundStyle(.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// The detail and the time: "on #142, 9 minutes ago", "last changed 4
    /// minutes ago".
    private func detail(now: Date) -> String? {
        var parts: [String] = []
        if let detail = card.headline.detail(numberFormat) {
            parts.append(detail)
        }
        switch card.time {
        case .lastChanged(let date)?:
            parts.append("last changed " + RelativeTime.describe(date, now: now, formatting: formatting, timeZone: timeZone))
        case .at(let date)?:
            parts.append(RelativeTime.describe(date, now: now, formatting: formatting, timeZone: timeZone))
        case nil:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// What a card shows under its headline.
struct HomePeekView: View {
    let peek: HomePeek
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        switch peek {
        case .none:
            EmptyView()
        case .files(let files, let more):
            VStack(alignment: .leading, spacing: Metrics.Home.peekSpacing) {
                ForEach(files, id: \.path) { file in
                    HStack(spacing: Metrics.insetSmall) {
                        StatusGlyph(FileStatusKind(file.kind), size: Metrics.Home.peekTile)
                        Text(POSIXPath.basename(file.path))
                            .font(Typography.secondary)
                            .foregroundStyle(.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tooltip(file.path)
                    }
                }
                if more > 0 {
                    Text("and \(formatCount(more, numberFormat)) more")
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .padding(.leading, Metrics.Home.peekTile + Metrics.insetSmall)
                }
            }
        case .commits(let subjects, let more):
            VStack(alignment: .leading, spacing: Metrics.Home.peekSpacing) {
                ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
                    HStack(spacing: Metrics.insetSmall) {
                        HomeCommitBullet()
                        Text(subject)
                            .font(Typography.secondary)
                            .foregroundStyle(.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tooltip(subject)
                    }
                }
                if more > 0 {
                    Text("and \(formatCount(more, numberFormat)) more")
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .padding(.leading, Metrics.Home.peekTile + Metrics.insetSmall)
                }
            }
        case .pullRequest(let title):
            Text(title)
                .font(Typography.secondary)
                .foregroundStyle(.text)
                .lineLimit(2)
        case .merged:
            Text(peek.summary(numberFormat) ?? "")
                .font(Typography.secondary)
                .foregroundStyle(.text2)
        }
    }
}

/// A commit to push's bullet: a small ring, centered in a file tile's
/// width so the subjects line up with the files' names.
struct HomeCommitBullet: View {
    var body: some View {
        Circle()
            .strokeBorder(Color(espalier: Palette.text3), lineWidth: Metrics.Home.commitBulletLineWidth)
            .frame(width: Metrics.Home.commitBullet, height: Metrics.Home.commitBullet)
            .frame(width: Metrics.Home.peekTile, height: Metrics.Home.peekTile)
            .accessibilityHidden(true)
    }
}

nonisolated extension Metrics.Home {
    /// The widest the text that tells two same-named repositories apart
    /// gets.
    public static let ownerMaxWidth: CGFloat = 160

    /// A commit to push's ring, and its line.
    public static let commitBullet: CGFloat = 7
    public static let commitBulletLineWidth: CGFloat = 1.5
}

extension HomePeek {
    /// The peek in one line, for a plain row: the files' names, the commits'
    /// subjects, the pull request's title, or what's left of merged work.
    func summary(_ format: NumberFormat) -> String? {
        switch self {
        case .none:
            return nil
        case .files(let files, let more):
            let names = files.map { POSIXPath.basename($0.path) }.joined(separator: ", ")
            return more > 0 ? "\(names), and \(formatCount(more, format)) more" : names
        case .commits(let subjects, let more):
            let joined = subjects.joined(separator: ", ")
            return more > 0 ? "\(joined), and \(formatCount(more, format)) more" : joined
        case .pullRequest(let title):
            return title
        case .merged(let keepsWorktree):
            return keepsWorktree ? "Its worktree and branch are still on this Mac." : "Its branch is still on this Mac."
        }
    }
}

extension FileStatusKind {
    /// The status a work's sample names.
    init(_ kind: AppFileStatusKind) {
        switch kind {
        case .new: self = .new
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .copied: self = .copied
        case .renamed: self = .renamed
        case .conflicted: self = .conflicted
        case .untracked: self = .untracked
        }
    }
}

/// A card's next step: prominent on the focused card, quiet on the others;
/// while it runs in place, its arc and what it's doing.
struct HomeStepButton: View {
    let card: HomeCard
    let takeStep: (HomeCard) -> Void

    var body: some View {
        Button {
            takeStep(card)
        } label: {
            if card.isRunning {
                HStack(spacing: Metrics.Home.symbolSpacing) {
                    ArcProgress(.mini, tint: card.isFocused ? Palette.buttonText : Palette.text2)
                    Text(card.nextStep.runningTitle)
                }
            } else {
                Text(card.nextStep.title)
            }
        }
        .buttonStyle(CapsuleButtonStyle(card.isFocused ? .prominent : .quiet))
        .disabled(card.route == nil || card.isRunning)
        .fixedSize()
    }
}

extension WorkNextStep {
    /// What a step that runs in place says while it runs.
    var runningTitle: String {
        switch self {
        case .push: "Pushing…"
        case .cleanUp: "Cleaning Up…"
        default: title
        }
    }
}

/// The pending counts, the same pills the repository popover draws:
/// changed files, ahead, and behind.
struct HomePendingCounts: View {
    let card: HomeCard

    var body: some View {
        RepositoryStatusIndicators(content: RepositoryRowContent(
            id: .repository(card.id.repositoryID),
            title: card.title,
            icon: .repository,
            changedFileCount: card.changedFiles,
            ahead: card.ahead,
            behind: card.behind,
            showsStatus: true,
            fullName: card.title,
            path: card.id.path
        ))
    }
}

// MARK: - In Progress

/// In Progress: a row for each piece of work, in one card, or split by
/// hairlines where the theme draws plainly.
struct HomeProgressList: View {
    let rows: [HomeProgressRow]
    let actions: HomeViewActions
    @Environment(\.motion) private var motion

    var body: some View {
        switch HomeThemeStyle.current.inProgress {
        case .card:
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HomeProgressRowView(row: row, actions: actions)
                        .transition(motion.animates ? .opacity : .identity)
                }
            }
            .padding(Metrics.Home.progressInset)
            .frame(maxWidth: .infinity)
            .environment(\.isInPaneCard, true)
            .homeCardSurface(in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        case .hairlines:
            HomeHairlineList(rows) { row in
                HomeProgressRowView(row: row, actions: actions)
            }
        }
    }
}

/// One piece of work in progress: the turning arc, or a clock for work
/// waiting on checks; the repository, the branch, the phase, and its detail
/// at the trailing edge. A click opens it.
struct HomeProgressRowView: View {
    let row: HomeProgressRow
    let actions: HomeViewActions
    @State private var isHovered = false
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        Button {
            actions.open(row.id)
        } label: {
            HStack(spacing: Metrics.Home.symbolSpacing + 3) {
                ZStack {
                    switch row.phase {
                    case .changingNow:
                        ArcProgress(.small, tint: WorkMark.changingNow.color)
                    case .waitingOnChecks:
                        Image(systemName: WorkMark.waitingOnChecks.systemImage ?? "clock")
                            .font(.system(size: Metrics.Home.markSize))
                            .foregroundStyle(Color(espalier: WorkMark.waitingOnChecks.color))
                    }
                }
                .frame(width: Metrics.symbolWidth)
                .accessibilityHidden(true)
                HomeRepositoryTitle(title: row.title, owner: row.owner, font: Typography.row.weight(.bold))
                if let branch = row.branch {
                    HomeBranchView(branch: branch)
                }
                Text(row.phase.title)
                    .font(Typography.row)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .padding(.leading, Metrics.grid)
                Spacer(minLength: Metrics.insetSmall)
                if let detail = row.phase.detail(numberFormat) {
                    Text(detail)
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.Home.rowPadding)
            .frame(minHeight: Metrics.Home.progressRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(Color(espalier: Palette.hover))
                    .opacity(isHovered ? 1 : 0)
                    .hoverMotion(isHovered)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .onHover { isHovered = $0 }
        .contextMenuCard {
            actions.menu(row.id)
        }
    }
}

// MARK: - Quiet

/// The Quiet line: the chevron, "Quiet", how many repositories are clean
/// and in sync, and their names trailing off; open, the repositories in
/// groups, one for each owner (`HomeQuietGroups`).
struct HomeQuietSection: View {
    let content: HomeContent
    @Binding var isOpen: Bool
    let openRepository: (RepositoryID) -> Void
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            Button {
                withMotion(motion, Motion.arrive) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: Metrics.insetSmall) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.text3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: Metrics.symbolWidth)
                    Text("Quiet")
                        .font(Typography.row.weight(.bold))
                        .foregroundStyle(.text)
                    Text(content.quietSummary(numberFormat))
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .contentTransition(motion.animates ? .numericText() : .identity)
                        .motion(Motion.kindChange, value: content.quiet.count)
                    if !isOpen {
                        Text(content.quiet.map(\.name).joined(separator: ", "))
                            .font(Typography.row)
                            .foregroundStyle(.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, Metrics.grid)
                            .transition(motion.animates ? .opacity : .identity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.ListRow.height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
            .accessibilityValue(isOpen ? "Open" : "Closed")
            .padding(.horizontal, Metrics.Home.labelInset)
            if isOpen {
                HomeQuietGroups(groups: content.quietGroups, openRepository: openRepository)
                    .transition(motion.animates ? .opacity : .identity)
            }
        }
    }
}

extension HomeQuietRepository {
    /// Its title, with its owner where the title is ambiguous.
    var name: String {
        owner.map { "\(title) (\($0))" } ?? title
    }
}

/// The quiet repositories' groups in as many columns as cards fit, each
/// group under the shortest column so far (`HomeColumns`), so they line up
/// with Needs You's cards. The rows' times tick once a minute.
struct HomeQuietGroups: View {
    let groups: [HomeQuietGroup]
    let openRepository: (RepositoryID) -> Void
    @Environment(\.scheduler) private var scheduler
    @Environment(\.motion) private var motion

    var body: some View {
        // Ticks once a minute, telling time by the app's clock.
        TimelineView(.everyMinute) { _ in
            let now = scheduler.now
            HomeColumns(spacing: Metrics.Home.cardSpacing) {
                ForEach(groups) { group in
                    HomeQuietGroupView(group: group, now: now, openRepository: openRepository)
                        .transition(motion.animates ? .opacity : .identity)
                }
            }
        }
    }
}

/// One owner's quiet repositories: the owner and how many there are, then a
/// row for each. The group is a card on the backdrop, or sits under a
/// hairline where the theme draws plainly.
struct HomeQuietGroupView: View {
    let group: HomeQuietGroup
    let now: Date
    let openRepository: (RepositoryID) -> Void
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        switch HomeThemeStyle.current.quiet {
        case .cards:
            rows(dividesHeader: false)
                .padding(Metrics.Home.quietGroupInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.isInPaneCard, true)
                .homeCardSurface(in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        case .hairlines:
            rows(dividesHeader: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rows(dividesHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                // A folder is cut at its head, so the folder nearest the
                // repositories stays.
                Text(group.name)
                    .font(Typography.row.weight(.bold))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .tooltip(group.name)
                Text(verbatim: formatCount(group.repositories.count, numberFormat))
                    .font(Typography.count)
                    .foregroundStyle(.text3)
            }
            .padding(.horizontal, Metrics.Home.quietRowPadding)
            .frame(minHeight: Metrics.Home.quietHeaderHeight)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if dividesHeader {
                Hairline()
            }
            ForEach(group.repositories) { repository in
                HomeQuietRow(repository: repository, now: now) {
                    openRepository(repository.id)
                }
            }
        }
    }
}

/// A quiet repository: its title, its folder where its group has another
/// of that title, its branch when it's off its default branch, and when it
/// last changed at the trailing edge. A click opens it.
struct HomeQuietRow: View {
    let repository: HomeQuietRepository
    let now: Date
    let open: () -> Void
    @State private var isHovered = false
    @Environment(\.dateTimeFormatting) private var formatting
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Button(action: open) {
            HStack(spacing: Metrics.insetSmall) {
                Text(repository.title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let folder = repository.folder {
                    Text(folder)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .tooltip(folder)
                }
                if let branch = repository.branch {
                    HomeBranchView(branch: branch, size: .small)
                }
                Spacer(minLength: Metrics.insetSmall)
                if let lastChanged = repository.lastChanged {
                    Text(RelativeTime.describe(lastChanged, now: now, formatting: formatting, timeZone: timeZone))
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Metrics.Home.quietRowPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.Home.quietRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(Color(espalier: Palette.hover))
                    .opacity(isHovered ? 1 : 0)
                    .hoverMotion(isHovered)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous))
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .onHover { isHovered = $0 }
    }
}

nonisolated extension Metrics.Home {
    /// Inside a quiet group's card.
    public static let quietGroupInset: CGFloat = 8
    /// A quiet group's name and count.
    public static let quietHeaderHeight: CGFloat = 34
    /// A quiet repository's row, and its sides.
    public static let quietRowHeight: CGFloat = 30
    public static let quietRowPadding: CGFloat = 10
}

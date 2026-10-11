// A pull request's checks, as the pull request's place and the checks
// popover list them: the summary's title and line with Re-run, workflow
// groups, a check expanding to its steps (the first failed one already
// open) with its own Re-run and View on GitHub, steps a click opens on
// GitHub, and "There are no steps to display for this check.". Shapes
// differ per state, so color never stands alone.

import EspalierCore
import GitHubKit
import SwiftUI

/// A check's or a step's state, as its glyph shows it.
nonisolated enum CheckGlyphKind: String, Sendable, Equatable, CaseIterable {
    case success, failure, actionRequired, cancelled, neutral, skipped, stale, pending

    init(status: APICheckStatus, conclusion: APICheckConclusion?) {
        guard status == .completed || conclusion != nil, let conclusion else {
            self = .pending
            return
        }
        switch conclusion {
        case .success: self = .success
        case .failure, .timedOut: self = .failure
        case .actionRequired: self = .actionRequired
        case .canceled: self = .cancelled
        case .neutral: self = .neutral
        case .skipped: self = .skipped
        case .stale: self = .stale
        default: self = .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .actionRequired: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        case .neutral: "minus.circle.fill"
        case .skipped: "forward.circle.fill"
        case .stale: "arrow.clockwise.circle.fill"
        case .pending: "clock.fill"
        }
    }

    /// The color family.
    var tone: ChecksState {
        switch self {
        case .success: .success
        case .failure, .actionRequired: .failure
        case .pending: .pending
        case .cancelled, .neutral, .skipped, .stale: .neutral
        }
    }
}

extension ChecksState {
    /// The overall state of a pull request's checks, or nil when it has
    /// none (no glyph shows then).
    nonisolated init?(_ check: CombinedRefCheck?) {
        guard let check, !check.checks.isEmpty else {
            return nil
        }
        self = CheckGlyphKind(status: check.status, conclusion: check.conclusion).tone
    }
}

/// The tooltip of a pull request's checks glyph: "Checks: Successful".
nonisolated func checksTooltipText(_ check: CombinedRefCheck) -> String {
    "Checks: \(getCheckRunConclusionAdjective(check.conclusion))"
}

/// A check's or a step's glyph.
struct CheckGlyph: View {
    let kind: CheckGlyphKind

    var body: some View {
        Image(systemName: kind.systemImage)
            .foregroundStyle(Color(espalier: Palette.checks(kind.tone)))
            .accessibilityLabel(getCheckRunConclusionAdjective(kind.conclusion))
    }
}

extension CheckGlyphKind {
    /// The conclusion the kind stands for, for its words.
    nonisolated var conclusion: APICheckConclusion? {
        switch self {
        case .success: .success
        case .failure: .failure
        case .actionRequired: .actionRequired
        case .cancelled: .canceled
        case .neutral: .neutral
        case .skipped: .skipped
        case .stale: .stale
        case .pending: nil
        }
    }
}

// MARK: Content

/// A step of a GitHub Actions check. Its duration and page are worked out
/// when it shows: only an open check's steps do, and a pull request can
/// have hundreds.
nonisolated struct CheckStepContent: Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var glyph: CheckGlyphKind
    /// The API's timestamps.
    var startedAt: String?
    var completedAt: String?
    /// The step's page.
    var urlString: String?

    /// "1m 30s", or empty when unknown.
    var duration: String {
        getFormattedCheckRunDuration(completedAt: completedAt, startedAt: startedAt)
    }

    var url: URL? {
        urlString.flatMap(URL.init(string:))
    }
}

/// A check in the list.
nonisolated struct CheckRunContent: Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    /// "Successful in 3m 2s", "Failed after 1m".
    var description: String
    var glyph: CheckGlyphKind
    /// The check's page, or the pull request's.
    var url: URL?
    /// Its steps, for a GitHub Actions check; nil for others.
    var steps: [CheckStepContent]?
    /// "3 successful steps".
    var stepsSummary: String?
    /// Whether it can be rerun on its own (a GitHub Actions job).
    var canRerun: Bool
}

/// A group of checks: a workflow, with its event when several ran.
nonisolated struct CheckGroupContent: Sendable, Equatable, Identifiable {
    /// The group's name, or nil when the list has only one group of other
    /// checks (no header shows then).
    var name: String?
    var checks: [CheckRunContent]

    var id: String {
        name ?? ""
    }
}

/// How the checks can be rerun.
nonisolated enum CheckRerunOptions: Sendable, Equatable {
    /// The server can't rerun checks.
    case none
    /// "Re-run Checks".
    case all
    /// "Re-run ⌄": Re-run Failed Checks, Re-run All Checks.
    case failedOrAll
}

/// A pull request's checks, for the list and its header.
nonisolated struct ChecksContent: Sendable, Equatable {
    /// "All checks have passed", "Some checks were not successful", ...
    var title: String
    /// "2 successful and 1 failed checks".
    var summary: String
    /// The overall state, or nil while loading with nothing to show.
    var overall: ChecksState?
    var groups: [CheckGroupContent]
    /// Whether the list is waiting for the checks (with their workflows'
    /// steps): "Stand By".
    var isLoading: Bool
    /// Whether the pull request has no checks at all.
    var isEmpty: Bool
    var rerun: CheckRerunOptions
    /// Whether rerunning is possible now (checks are listed).
    var canRerun: Bool
    /// The check open at first: the first failed one with steps.
    var initiallyExpanded: Int?

    /// The content for `check` (nil: none loaded).
    ///
    /// - Parameters:
    ///   - loaded: Whether the checks have loaded (with the branch's
    ///     workflows, when the list shows steps).
    ///   - repository: The pull request's base repository, for links.
    ///   - pullRequestNumber: The pull request, for links.
    ///   - rerunSupport: What the server can rerun.
    init(
        check: CombinedRefCheck?,
        loaded: Bool,
        repository: GitHubRepository?,
        pullRequestNumber: Int,
        rerunSupport: (checks: Bool, individualOrFailed: Bool)
    ) {
        let checks = check?.checks ?? []
        // Only show the loading header status if there are no cached check
        // runs to display.
        title = getChecksSummaryTitle(checks, loading: !loaded)
        summary = checks.isEmpty ? "" : getCombinedStatusSummary(checks.map(\.conclusion), description: "check")
        overall = ChecksState(check)
        isLoading = !loaded
        isEmpty = loaded && checks.isEmpty
        let pullRequestURL = repository.flatMap { GitHubWebURLs.pullRequest(number: pullRequestNumber, in: $0) }

        let grouped = getCheckRunsGroupedByActionWorkflowNameAndEvent(checks)
        let showsNames = !(grouped.count == 1 && grouped[0].name == "Other")
        groups = grouped.map { group in
            CheckGroupContent(name: showsNames ? group.name : nil, checks: group.checks.map { check in
                CheckRunContent(
                    id: check.id,
                    name: check.name,
                    description: check.description,
                    glyph: CheckGlyphKind(status: check.status, conclusion: check.conclusion),
                    url: check.htmlURL.flatMap(URL.init(string:)) ?? pullRequestURL,
                    steps: check.actionJobSteps.map { steps in
                        steps.map { step in
                            CheckStepContent(
                                id: step.number,
                                name: step.name,
                                glyph: CheckGlyphKind(status: step.status, conclusion: step.conclusion),
                                startedAt: step.startedAt,
                                completedAt: step.completedAt,
                                urlString: repository.flatMap { getCheckRunStepURL(check, step, $0, pullRequestNumber) }
                            )
                        }
                    },
                    stepsSummary: check.actionJobSteps.map { steps in
                        getCombinedStatusSummary(steps.map(\.conclusion), description: "step")
                    },
                    canRerun: rerunSupport.individualOrFailed && check.actionJobSteps != nil
                )
            })
        }

        if !rerunSupport.checks {
            rerun = .none
        } else if rerunSupport.individualOrFailed, checks.contains(where: { $0.conclusion == .failure }) {
            rerun = .failedOrAll
        } else {
            rerun = .all
        }
        canRerun = !checks.isEmpty && loaded

        // If there is a failure, we want the first check run with a failure
        // to be opened so the user doesn't have to click through to find it.
        initiallyExpanded = grouped.lazy.compactMap { group in
            group.checks.first { isFailure($0) && $0.actionJobSteps != nil }
        }.first?.id
    }
}

/// What the checks' buttons do.
struct ChecksListActions {
    /// Opens a check's or a step's page.
    var open: (URL) -> Void
    /// Reruns: failed ones only, or all; or one check (`checkID`).
    var rerun: (_ failedOnly: Bool, _ checkID: Int?) -> Void

    static let none = ChecksListActions(open: { _ in }, rerun: { _, _ in })
}

// MARK: Views

/// The checks' summary: the state's glyph, the title, the summary line,
/// and Re-run.
struct ChecksHeader: View {
    let content: ChecksContent
    let actions: ChecksListActions

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            Group {
                if let overall = content.overall {
                    ChecksGlyph(overall)
                } else {
                    ArcProgress(.small)
                }
            }
            .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(Typography.heading)
                if !content.summary.isEmpty {
                    Text(content.summary)
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: Metrics.insetSmall)
            ChecksRerunButton(options: content.rerun, isEnabled: content.canRerun) { failedOnly in
                actions.rerun(failedOnly, nil)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Re-run Checks", or "Re-run ⌄" with failed and all.
struct ChecksRerunButton: View {
    let options: CheckRerunOptions
    let isEnabled: Bool
    let rerun: (_ failedOnly: Bool) -> Void

    var body: some View {
        switch options {
        case .none:
            EmptyView()
        case .all:
            Button {
                rerun(false)
            } label: {
                Label("Re-run Checks", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .fixedSize()
            .disabled(!isEnabled)
        case .failedOrAll:
            PullDownButton("Re-run") { [rerun] in
                MenuAction("Re-run Failed Checks") {
                    rerun(true)
                }
                MenuAction("Re-run All Checks") {
                    rerun(false)
                }
            } label: {
                MenuCapsuleLabel("Re-run", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .fixedSize()
            .disabled(!isEnabled)
        }
    }
}

/// The checks, grouped, each expanding to its steps.
struct ChecksList: View {
    let content: ChecksContent
    let actions: ChecksListActions
    @State private var expanded: Int?
    @State private var hasUserToggled = false

    var body: some View {
        Group {
            if content.isLoading {
                ChecksStandBy()
            } else if content.isEmpty {
                Text("There are no checks for this pull request.")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
            } else {
                VStack(alignment: .leading, spacing: Metrics.grid) {
                    ForEach(content.groups) { group in
                        if let name = group.name {
                            Text(name)
                                .font(Typography.subheadline.weight(.semibold))
                                .foregroundStyle(.text2)
                                .padding(.top, Metrics.grid)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.checks) { check in
                            CheckRunRow(
                                check: check,
                                isExpanded: expandedID == check.id,
                                toggle: {
                                    hasUserToggled = true
                                    expanded = expandedID == check.id ? -1 : check.id
                                },
                                actions: actions
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The check open: the user's choice, else the first failed one.
    private var expandedID: Int? {
        hasUserToggled ? expanded : content.initiallyExpanded
    }
}

/// The loading copy: "Stand By" / "Check runs incoming!".
struct ChecksStandBy: View {
    var body: some View {
        VStack(spacing: Metrics.grid) {
            Text("Stand By")
                .font(Typography.heading)
            Text("Check runs incoming!")
                .font(Typography.secondary)
                .foregroundStyle(.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.insetMedium)
        .accessibilityElement(children: .combine)
    }
}

/// A check: its glyph, name, and description; open, its steps.
private struct CheckRunRow: View {
    let check: CheckRunContent
    let isExpanded: Bool
    let toggle: () -> Void
    let actions: ChecksListActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                    CheckGlyph(kind: check.glyph)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(check.description)
                            .font(Typography.subheadline)
                            .foregroundStyle(.text2)
                    }
                    Spacer(minLength: Metrics.grid)
                    Image(systemName: "chevron.right")
                        .font(Typography.subheadline)
                        .foregroundStyle(.text3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .motion(Motion.leave, value: isExpanded)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
            .tooltip(check.name)
            .accessibilityLabel("\(check.name), \(check.description)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                CheckStepsView(check: check, actions: actions)
                    .padding(.leading, Metrics.insetLarge + Metrics.grid)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An expanded check: its steps' summary, Re-run and View on GitHub as
/// symbol buttons, then its steps or the note that it has none with View
/// Check Details.
private struct CheckStepsView: View {
    let check: CheckRunContent
    let actions: ChecksListActions

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            if let steps = check.steps {
                HStack(spacing: Metrics.grid) {
                    if let summary = check.stepsSummary {
                        Text(summary)
                            .font(Typography.subheadline.weight(.semibold))
                            .foregroundStyle(.text2)
                    }
                    Spacer(minLength: Metrics.grid)
                    if check.canRerun {
                        Button {
                            actions.rerun(false, check.id)
                        } label: {
                            Label("Re-run \(check.name)", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.icon)
                        .tooltip("Re-run \(check.name)")
                    }
                    if let url = check.url {
                        Button {
                            actions.open(url)
                        } label: {
                            Label("View \(check.name) on GitHub", systemImage: "arrow.up.forward.square")
                        }
                        .buttonStyle(.icon)
                        .tooltip("View \(check.name) on GitHub")
                    }
                }
                ForEach(steps) { step in
                    CheckStepRow(step: step, open: actions.open)
                }
            } else {
                VStack(alignment: .leading, spacing: Metrics.insetSmall) {
                    Text("There are no steps to display for this check.")
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = check.url {
                        Button("View Check Details") {
                            actions.open(url)
                        }
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// A step: its glyph, name, and duration. A step with a page opens it on a
/// click, the row taking the hover wash and showing ↗ while the pointer is
/// on it.
private struct CheckStepRow: View {
    let step: CheckStepContent
    let open: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        if let url = step.url {
            Button {
                open(url)
            } label: {
                row(showsLink: isHovered)
            }
            .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .continuous)
                    .fill(isHovered ? Color(espalier: Palette.hover) : .clear)
                    .hoverMotion(isHovered)
                    .padding(.horizontal, -Metrics.grid)
            )
            .onHover { isHovered = $0 }
            .tooltip("View \(step.name) on GitHub")
            .accessibilityHint("Opens the step on GitHub")
        } else {
            row(showsLink: false)
                .tooltip(step.name)
        }
    }

    private func row(showsLink: Bool) -> some View {
        HStack(spacing: Metrics.insetSmall) {
            CheckGlyph(kind: step.glyph)
                .font(Typography.subheadline)
            Text(step.name)
                .font(Typography.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Metrics.grid)
            Text(step.duration)
                .font(Typography.subheadline.monospacedDigit())
                .foregroundStyle(.text2)
            Image(systemName: "arrow.up.forward")
                .font(Typography.subheadline)
                .foregroundStyle(.text3)
                .opacity(showsLink ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

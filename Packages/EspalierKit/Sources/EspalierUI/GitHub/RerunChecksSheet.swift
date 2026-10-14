// The Re-run sheet: which checks will run again, the ones that can't and why
// (`CheckRerunPlan` words them), and the button. While it works out which
// checks can run again (for more than one), it says "Please wait" /
// "Determining which checks can be re-run.".

import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// What the Re-run sheet shows.
nonisolated struct RerunChecksContent: Sendable, Equatable {
    /// "Re-run Checks", "Re-run Failed Checks", "Re-run Single Check".
    var title: String
    /// "Re-run Checks", "Re-run Check".
    var confirmTitle: String
    /// Whether it's still working out which checks can run again.
    var isDetermining: Bool
    /// "<name> will run again, along with the checks that depend on it."
    var dependentsMessage: String?
    /// The checks that will run again: glyph and name.
    var rerunnable: [CheckRunContent]
    /// Why some checks can't run again.
    var warning: String?
    /// Whether the button works.
    var canRerun: Bool

    /// The title: "Re-run " + "Single " (one check) or "Failed " (failed
    /// ones), then "Check" or "Checks".
    static func title(checkCount: Int, failedOnly: Bool, showsDescriptor: Bool = true) -> String {
        var descriptor = ""
        if showsDescriptor, checkCount == 1 {
            descriptor = "Single "
        }
        if showsDescriptor, failedOnly {
            descriptor = "Failed "
        }
        return "Re-run \(descriptor)Check\(checkCount == 1 ? "" : "s")"
    }

    init(checks: [RefCheck], failedOnly: Bool, plan: CheckRerunPlan?, isRerunning: Bool) {
        title = Self.title(checkCount: checks.count, failedOnly: failedOnly)
        confirmTitle = Self.title(checkCount: checks.count, failedOnly: failedOnly, showsDescriptor: false)
        isDetermining = plan == nil && checks.count > 1
        dependentsMessage = plan?.dependentsMessage(allChecks: checks)
        rerunnable = (plan?.rerunnable ?? []).map { check in
            CheckRunContent(
                id: check.id,
                name: check.name,
                description: check.description,
                glyph: CheckGlyphKind(status: check.status, conclusion: check.conclusion),
                url: nil,
                steps: nil,
                stepsSummary: nil,
                canRerun: false
            )
        }
        warning = plan?.warning
        canRerun = !(plan?.rerunnable.isEmpty ?? true) && !isRerunning
    }
}

/// The sheet's work: which checks can run again, then running them.
@MainActor @Observable
final class RerunChecksFlow {
    let repository: RepositoryModel
    let pullRequest: PullRequest
    let checks: [RefCheck]
    let failedOnly: Bool
    /// Which checks can run again; nil until it's worked out.
    private(set) var plan: CheckRerunPlan?
    private(set) var isRerunning = false

    init(repository: RepositoryModel, pullRequest: PullRequest, checks: [RefCheck], failedOnly: Bool) {
        self.repository = repository
        self.pullRequest = pullRequest
        self.checks = checks
        self.failedOnly = failedOnly
    }

    var content: RerunChecksContent {
        RerunChecksContent(checks: checks, failedOnly: failedOnly, plan: plan, isRerunning: isRerunning)
    }

    /// Works out which checks can run again, from their check suites.
    func determinePlan() async {
        plan = await repository.gitHub.rerunPlan(for: pullRequest, checks: checks, failedOnly: failedOnly)
    }

    /// Runs the plan's checks again; false when there's no plan yet,
    /// nothing in it can run again, or it's already running.
    func rerun() async -> Bool {
        guard let plan, !plan.rerunnable.isEmpty, !isRerunning else {
            return false
        }
        isRerunning = true
        await repository.gitHub.rerunChecks(plan, for: pullRequest)
        return true
    }
}

/// Re-runs a pull request's checks.
struct RerunChecksSheet: View {
    static let sheetID = "espalier.github.rerunChecks"

    @State private var flow: RerunChecksFlow
    @Environment(\.dismissModal) private var dismissModal

    init(repository: RepositoryModel, pullRequest: PullRequest, checks: [RefCheck], failedOnly: Bool) {
        _flow = State(initialValue: RerunChecksFlow(repository: repository, pullRequest: pullRequest, checks: checks, failedOnly: failedOnly))
    }

    var body: some View {
        RerunChecksView(
            content: flow.content,
            cancel: { dismissModal() },
            rerun: {
                Task {
                    if await flow.rerun() {
                        dismissModal()
                    }
                }
            }
        )
        .task {
            await flow.determinePlan()
        }
    }

    /// The checks the sheet re-runs: the pull request's, or the one
    /// `checkID` names.
    @MainActor
    static func checks(of pullRequest: PullRequest, in repository: RepositoryModel, checkID: Int?) -> [RefCheck] {
        let checks = repository.gitHub.checks(for: pullRequest)?.checks ?? []
        guard let checkID else {
            return checks
        }
        return checks.filter { $0.id == checkID }
    }

    /// Shows the sheet for the pull request's checks: all of them, the
    /// failed ones, or the one `checkID` names.
    @MainActor
    static func present(repository: RepositoryModel, pullRequest: PullRequest, failedOnly: Bool, checkID: Int?, in context: WindowContext) {
        let checks = checks(of: pullRequest, in: repository, checkID: checkID)
        guard !checks.isEmpty else {
            return
        }
        context.modals.presentSheet(id: sheetID) {
            RerunChecksSheet(repository: repository, pullRequest: pullRequest, checks: checks, failedOnly: failedOnly)
        }
    }
}

/// The sheet's content.
struct RerunChecksView: View {
    let content: RerunChecksContent
    let cancel: () -> Void
    let rerun: () -> Void

    var body: some View {
        SheetScaffold(content.title) {
            if content.isDetermining {
                VStack(spacing: Metrics.grid) {
                    ArcProgress(.small)
                    Text("Please wait")
                        .font(Typography.heading)
                        .foregroundStyle(.text)
                    Text("Determining which checks can be re-run.")
                        .font(Typography.secondary)
                        .foregroundStyle(.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.insetMedium)
            } else {
                if let message = content.dependentsMessage {
                    Text(message)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !content.rerunnable.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                        ForEach(content.rerunnable) { check in
                            HStack(spacing: Metrics.insetSmall) {
                                CheckGlyph(kind: check.glyph)
                                    .tooltip(check.glyph.adjective)
                                Text(check.name)
                                    .foregroundStyle(.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(Metrics.insetMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
                if let warning = content.warning {
                    Label {
                        Text(warning)
                            .foregroundStyle(.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        WarningGlyph()
                    }
                    .font(Typography.secondary)
                }
            }
        } buttons: {
            SheetButtons(content.confirmTitle, isConfirmDisabled: !content.canRerun, cancel: cancel, confirm: rerun)
        }
    }
}

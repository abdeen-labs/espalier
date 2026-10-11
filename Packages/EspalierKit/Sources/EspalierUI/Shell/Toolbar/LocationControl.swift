// Ported in part from desktop/app/src/ui/toolbar/branch-dropdown.tsx
//
// The location control, in Xcode's scheme/destination pattern: one capsule
// with a repository segment and a branch segment (its titles, tooltips, and
// states), each opening a popover.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the location control shows.
nonisolated public struct LocationControlState: Sendable, Equatable {
    /// The repository segment.
    public enum RepositorySegment: Sendable, Equatable {
        case noRepositories
        case selectRepository
        /// A repository: its name, and its path for the tooltip.
        case repository(name: String, path: String)
        /// A repository being cloned.
        case cloning(name: String)
    }

    /// The branch segment.
    public enum BranchSegment: Sendable, Equatable {
        /// Hidden: unknown tip, no repository, missing, unsafe, or cloning.
        case hidden
        case branch(name: String)
        /// "Current branch is <ref>".
        case unborn(ref: String)
        /// "On a1b2c3d".
        case detached(sha: String)
        /// Checking out: the target and progress; disabled.
        case checkingOut(target: String, description: String, progress: Double)
        /// "Rebasing <target>": a rebase, squash, or reorder stopped on
        /// conflicts or interrupted; disabled.
        case rebasing(target: String)
    }

    public var repository: RepositorySegment
    public var branch: BranchSegment
    /// Why the branch segment is disabled while it shows the branch: an
    /// operation in progress refuses switching branches ("Finish or abort
    /// the merge first."), its tooltip. Nil when it opens.
    public var branchBlockedReason: String?

    public init(repository: RepositorySegment, branch: BranchSegment, branchBlockedReason: String? = nil) {
        self.repository = repository
        self.branch = branch
        self.branchBlockedReason = branchBlockedReason
    }

    /// The repository segment's title.
    public var repositoryTitle: String {
        switch repository {
        case .noRepositories: "No Repositories"
        case .selectRepository: "Select a Repository"
        case .repository(let name, _), .cloning(let name): name
        }
    }

    /// What the control's width depends on: its two titles.
    var measuredTitles: String {
        "\(repositoryTitle)\u{0}\(branchTitle ?? "")"
    }

    /// The repository segment's tooltip.
    public var repositoryTooltip: String? {
        switch repository {
        case .repository(_, let path): path
        case .cloning(let name): "Cloning \(name)"
        case .noRepositories, .selectRepository: nil
        }
    }

    /// The branch segment's title.
    public var branchTitle: String? {
        switch branch {
        case .hidden: nil
        case .branch(let name): name
        case .unborn(let ref): ref
        case .detached(let sha): "On \(JSCompat.prefix(sha, 7))"
        case .checkingOut(let target, _, _): target
        case .rebasing(let target): "Rebasing \(target)"
        }
    }

    /// The branch segment's tooltip, or why it's disabled.
    public var branchTooltip: String? {
        if let branchBlockedReason, branch != .hidden {
            return branchBlockedReason
        }
        return switch branch {
        case .hidden: nil
        case .branch(let name): name
        case .unborn(let ref): "Current branch is \(ref)"
        case .detached: "Currently on a detached HEAD"
        case .checkingOut(let target, let description, let progress):
            progress > 0
                ? "Checking out \(target)\n\(description) (\(Int((progress * 100).rounded()))%)"
                : "Checking out \(target)\n\(description)"
        case .rebasing(let target): "Rebasing \(target)"
        }
    }

    /// The branch segment's symbol.
    public var branchSystemImage: String {
        switch branch {
        case .detached: "smallcircle.filled.circle"
        default: "arrow.trianglehead.branch"
        }
    }

    /// Whether the branch segment opens its popover.
    public var isBranchEnabled: Bool {
        if branchBlockedReason != nil {
            return false
        }
        return switch branch {
        case .checkingOut, .rebasing, .hidden: false
        default: true
        }
    }

    /// The state for the app's selection.
    @MainActor
    public static func make(_ app: AppModel) -> LocationControlState {
        switch app.selection {
        case nil:
            return LocationControlState(repository: app.repositories.isEmpty ? .noRepositories : .selectRepository, branch: .hidden)
        case .clone(let id)?:
            let name = app.clones.clones.first { $0.id == id }?.name ?? "Repository"
            return LocationControlState(repository: .cloning(name: name), branch: .hidden)
        case .repository?:
            guard let repository = app.selectedRepository else {
                return LocationControlState(repository: .selectRepository, branch: .hidden)
            }
            let segment = RepositorySegment.repository(name: repository.record.displayName, path: repository.record.path)
            guard repository.isUsable else {
                return LocationControlState(repository: segment, branch: .hidden)
            }
            let branch = branchSegment(repository)
            let blockedReason: String? = switch branch {
            case .branch, .unborn, .detached: repository.operations.checkoutRefusal
            case .hidden, .checkingOut, .rebasing: nil
            }
            return LocationControlState(repository: segment, branch: branch, branchBlockedReason: blockedReason)
        }
    }

    @MainActor
    private static func branchSegment(_ repository: RepositoryModel) -> BranchSegment {
        if let operation = repository.localOperation, operation.kind == .checkoutBranch || operation.kind == .checkoutCommit {
            if case .checkout(let progress)? = operation.progress {
                return .checkingOut(target: progress.target, description: progress.description, progress: progress.value)
            }
        }
        if case .rebase(_, let targetBranch, _, _, _, _)? = repository.operations.conflictState {
            return .rebasing(target: targetBranch)
        }
        // A rebase git was interrupted in between commits is one too.
        if let operation = repository.operations.current, operation.phase == .interrupted, let target = operation.targetBranch {
            return .rebasing(target: target.name)
        }
        switch repository.gitState.tip {
        case .unknown: return .hidden
        case .unborn(let ref): return .unborn(ref: ref)
        case .detached(let sha): return .detached(sha: sha)
        case .valid(let branch): return .branch(name: branch.name)
        }
    }
}

/// The location control's look, value-driven (snapshots render each state):
/// one quiet capsule with the repository (a folder and its name), a
/// chevron, and the branch (its symbol in the current branch's accent, its
/// name, and a down chevron). Each part opens its popover.
public struct LocationControlView: View {
    private let state: LocationControlState
    private let onRepository: () -> Void
    private let onBranch: () -> Void
    /// The branch's name fades in as the control appears (after a switch).
    private let fadesInBranch: Bool
    @State private var branchOpacity: Double
    @Environment(\.motion) private var motion

    /// - Parameter fadesInBranch: The branch's name fades in over 0.15 s as
    ///   the control appears: it replaces the control of the branch the
    ///   user switched from (the toolbar measures a new control for each
    ///   pair of names).
    public init(_ state: LocationControlState, fadesInBranch: Bool = false, onRepository: @escaping () -> Void = {}, onBranch: @escaping () -> Void = {}) {
        self.state = state
        self.fadesInBranch = fadesInBranch
        self.onRepository = onRepository
        self.onBranch = onBranch
        _branchOpacity = State(initialValue: fadesInBranch ? 0 : 1)
    }

    public var body: some View {
        HStack(spacing: 0) {
            LocationSegment(action: onRepository) {
                HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
                    Image(systemName: "folder")
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                    Text(state.repositoryTitle)
                        .lineLimit(1)
                }
            }
            .tooltip(state.repositoryTooltip ?? state.repositoryTitle)
            .accessibilityLabel("Repository: \(state.repositoryTitle)")

            if let branchTitle = state.branchTitle {
                Image(systemName: "chevron.right")
                    .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .semibold))
                    .foregroundStyle(.text3)
                    .padding(.horizontal, -1)
                    .accessibilityHidden(true)
                LocationSegment(action: onBranch) {
                    HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
                        if case .checkingOut(_, _, let progress) = state.branch {
                            // It turns until git reports how far it has got.
                            ArcProgress(.mini, value: progress > 0 ? progress : nil)
                        } else {
                            Image(systemName: state.branchSystemImage)
                                .font(Typography.row)
                                .foregroundStyle(branchSymbolColor)
                        }
                        Text(branchTitle)
                            .lineLimit(1)
                            .opacity(branchOpacity)
                            .onAppear {
                                if branchOpacity < 1 {
                                    withMotion(motion, Motion.leave) {
                                        branchOpacity = 1
                                    }
                                }
                            }
                        if state.isBranchEnabled {
                            Image(systemName: "chevron.down")
                                .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .semibold))
                                .foregroundStyle(.text3)
                        }
                    }
                }
                .disabled(!state.isBranchEnabled)
                .tooltip(state.branchTooltip ?? branchTitle)
                .accessibilityLabel("Branch: \(branchTitle)")
            }
        }
        .font(Typography.button)
        .foregroundStyle(.text)
        .padding(.horizontal, Metrics.grid)
        .frame(height: Metrics.ControlHeight.toolbar)
        .surface(.quiet, elevation: .quiet)
    }

    /// The current branch's accent; a detached HEAD is neutral.
    private var branchSymbolColor: Color {
        if case .detached = state.branch {
            return .text2
        }
        return Color(nsColor: Palette.accent)
    }
}

/// One part of the location control: a plain button with a hover wash.
private struct LocationSegment<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background {
                    Capsule(style: .circular)
                        .fill(isHovered && isEnabled ? Color(nsColor: Palette.hover) : .clear)
                        .hoverMotion(isHovered)
                        .padding(.vertical, 3)
                }
                .contentShape(Capsule(style: .circular))
        }
        // Fades the label while disabled.
        .buttonStyle(.bare(.capsule))
        .onHover { isHovered = $0 }
    }
}

/// The toolbar's location control, with its popovers (⌘T and ⌘B).
struct LocationControl: View {
    @Environment(WindowContext.self) private var context
    /// The names the control showed last.
    @State private var shownTitles: ShownTitles?

    private struct ShownTitles: Equatable {
        var repository: String
        var branch: String?
    }

    var body: some View {
        @Bindable var state = context.state
        let control = LocationControlState.make(context.app)
        WholePointWidth {
            LocationControlView(control, fadesInBranch: isBranchSwitch(control), onRepository: {
                context.actions.perform(.switchRepository)
            }, onBranch: {
                context.actions.perform(.switchBranch)
            })
        }
        // The toolbar measures its item once: a new identity when the names
        // change makes it measure again, so a longer repository or branch
        // name than the first one shown isn't truncated.
        .id(control.measuredTitles)
        .onChange(of: control.measuredTitles, initial: true) {
            shownTitles = ShownTitles(repository: control.repositoryTitle, branch: control.branchTitle)
        }
        .popoverCard(isPresented: $state.isRepositoryPopoverPresented, title: "Repositories") {
            RepositoryPopover()
                .windowEnvironment(context)
        }
        .overlay {
            // The branch popover anchors on the control.
            Color.clear
                .allowsHitTesting(false)
                .popoverCard(isPresented: $state.isBranchPopoverPresented, title: "Branches") {
                    if let repository = context.repository {
                        BranchPopover(repository: repository)
                            .windowEnvironment(context)
                    }
                }
        }
        .contextMenuCard { [context] in
            if case .branch(let name) = LocationControlState.make(context.app).branch {
                MenuAction(ActionKind.renameBranch.title) { context.actions.perform(.renameBranch(name: name)) }
                MenuAction(ActionKind.copyBranchName.title) { context.actions.perform(.copyBranchName(name: name)) }
                MenuAction(ActionKind.viewBranchOnGitHub.title) { context.actions.perform(.viewBranchOnGitHub(name: name)) }
                MenuAction(ActionKind.viewPullRequestOnGitHub.title) { context.actions.perform(.viewPullRequestOnGitHub(number: nil)) }
                MenuDivider()
                MenuAction(ActionKind.deleteBranch.title) { context.actions.perform(.deleteBranch(name: name)) }
            }
        }
    }

    /// Whether `control` shows another branch of the repository shown
    /// last: its name fades in. Choosing another repository shows at once.
    private func isBranchSwitch(_ control: LocationControlState) -> Bool {
        guard let shownTitles, let shownBranch = shownTitles.branch, let branch = control.branchTitle else {
            return false
        }
        return shownTitles.repository == control.repositoryTitle && shownBranch != branch
    }
}

/// The location control's toolbar item: its content at its ideal width,
/// whatever width the toolbar proposes, and that width rounded up to a
/// whole point, the content at its leading edge. A title given a width,
/// even one a little wider than it needs, can truncate ("ui-audit" given
/// 215 points of the 214.5 it needs showed "ui-…"), and the toolbar rounds
/// the width it measures, which would cut a fraction of a point off.
struct WholePointWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else {
            return .zero
        }
        let size = content.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        return CGSize(width: size.width.rounded(.up), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: nil, height: bounds.height)
        )
    }
}

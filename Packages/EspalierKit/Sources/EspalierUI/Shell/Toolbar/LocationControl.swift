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
    /// How the branch compares with its upstream, once it's published;
    /// nil otherwise.
    public var aheadBehind: AheadBehind?

    public init(repository: RepositorySegment, branch: BranchSegment, branchBlockedReason: String? = nil, aheadBehind: AheadBehind? = nil) {
        self.repository = repository
        self.branch = branch
        self.branchBlockedReason = branchBlockedReason
        self.aheadBehind = aheadBehind
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
        "\(repositoryTitle)\u{0}\(branchTitle ?? "")\u{0}\(aheadBehind.map { "\($0.ahead) \($0.behind)" } ?? "")"
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
        case .detached(let sha): "On \(Self.shortSHA(sha))"
        case .checkingOut(let target, _, _): target
        case .rebasing(let target): "Rebasing \(target)"
        }
    }

    /// A detached HEAD's short SHA in the branch segment's title
    /// ("a1b2c3d"); nil on a branch.
    var detachedShortSHA: String? {
        guard case .detached(let sha) = branch else {
            return nil
        }
        return Self.shortSHA(sha)
    }

    private static func shortSHA(_ sha: String) -> String {
        JSCompat.prefix(sha, 7)
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

    /// How the branch compares with its upstream, as its row does: on a
    /// branch, the counts of a published branch ("↑2 ↓1").
    private var tracking: BranchTracking? {
        guard case .branch = branch, let aheadBehind else {
            return nil
        }
        return .aheadBehind(ahead: aheadBehind.ahead, behind: aheadBehind.behind)
    }

    /// The counts in the branch's pill ("↑2 ↓1"), in `numberFormat`; nil
    /// when in step with its upstream, or not on a published branch.
    func countsText(_ numberFormat: NumberFormat) -> String? {
        tracking?.countsText(numberFormat)
    }

    /// How the branch compares with its upstream, in words ("2 commits
    /// ahead"), in `numberFormat`.
    func trackingDescription(_ numberFormat: NumberFormat) -> String? {
        tracking?.description(numberFormat)
    }

    /// The branch's tooltip, with how it compares with its upstream on a
    /// new line ("main\n2 commits ahead").
    func branchTooltip(_ numberFormat: NumberFormat) -> String? {
        guard branchBlockedReason == nil, let tooltip = branchTooltip, let tracking = trackingDescription(numberFormat) else {
            return branchTooltip
        }
        return "\(tooltip)\n\(tracking)"
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
            return LocationControlState(repository: segment, branch: branch, branchBlockedReason: blockedReason, aheadBehind: repository.gitState.aheadBehind)
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

/// The location control's look, value-driven (`LocationControlState`):
/// one raised pillow on its lip, with the repository (its folder symbol and
/// its name in bold) and the branch as a candy pill in the branch's color (its
/// symbol, its name, how it compares with its upstream, and a down
/// chevron). Each part opens its popover.
public struct LocationControlView: View {
    private let state: LocationControlState
    private let branchColor: NSColor?
    private let onRepository: () -> Void
    private let onBranch: () -> Void
    /// The branch's name fades in as the control appears (after a switch).
    private let fadesInBranch: Bool

    /// - Parameters:
    ///   - branchColor: The branch's color (`BranchColors`); nil for the
    ///     accent, the current branch's.
    ///   - fadesInBranch: The branch's name fades in over 0.15 s as the
    ///     control appears: it replaces the control of the branch the
    ///     user switched from (the toolbar measures a new control for each
    ///     pair of names).
    public init(
        _ state: LocationControlState,
        branchColor: NSColor? = nil,
        fadesInBranch: Bool = false,
        onRepository: @escaping () -> Void = {},
        onBranch: @escaping () -> Void = {}
    ) {
        self.state = state
        self.branchColor = branchColor
        self.fadesInBranch = fadesInBranch
        self.onRepository = onRepository
        self.onBranch = onBranch
    }

    public var body: some View {
        HStack(spacing: Metrics.LocationControl.spacing) {
            LocationSegment(action: onRepository) {
                LocationRepositoryLabel(state: state)
            }
            .tooltip(state.repositoryTooltip ?? state.repositoryTitle)
            .accessibilityLabel("Repository: \(state.repositoryTitle)")

            if state.branchTitle != nil {
                LocationBranchPill(state: state, color: branchColor, size: .regular, fadesIn: fadesInBranch, action: onBranch)
            }
        }
        .padding(.horizontal, Metrics.LocationControl.inset)
        .frame(height: CapsuleButtonAppearance(kind: .quiet, controlSize: .large).capsuleHeight)
        .quietControlSurface()
        .onLip(CapsuleButtonAppearance(kind: .quiet, controlSize: .large).lip, isPressed: false)
    }
}

/// The repository's folder symbol and its name in bold, or the arc while
/// one clones.
struct LocationRepositoryLabel: View {
    let state: LocationControlState
    var font: Font = Typography.sans(size: 13, weight: .bold, relativeTo: .body)

    var body: some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            Group {
                if case .cloning = state.repository {
                    ArcProgress(.small)
                } else {
                    Image(systemName: "folder")
                        .foregroundStyle(.text2)
                }
            }
            .frame(width: Metrics.symbolWidth)
            Text(state.repositoryTitle)
                .font(font)
                .foregroundStyle(.text)
                .lineLimit(1)
        }
    }
}

/// The branch as a candy pill in its color: its symbol (the arc while
/// checking out), its name (a detached HEAD's SHA in the code font), how it
/// compares with its upstream ("↑2 ↓1"), and a down chevron while it opens
/// the branch popover. A click opens the popover; disabled (checking out,
/// rebasing, an operation refusing a switch), it fades and says why in its
/// tooltip.
struct LocationBranchPill: View {
    let state: LocationControlState
    let color: NSColor?
    let size: CandyPillSize
    var fadesIn = false
    let action: () -> Void
    @State private var opacity: Double?
    @State private var isHovered = false
    @Environment(\.motion) private var motion
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        if let title = state.branchTitle {
            Button(action: action) {
                CandyPill(color: pillColor, size: size) {
                    branchSymbol
                    branchText(title)
                        .truncationMode(.middle)
                        .opacity(opacity ?? (fadesIn ? 0 : 1))
                        .onAppear {
                            if fadesIn {
                                withMotion(motion, Motion.leave) {
                                    opacity = 1
                                }
                            }
                        }
                    if let counts = state.countsText(numberFormat) {
                        Text(counts)
                            .font(Typography.sans(size: size.fontSize - 1, weight: .heavy, relativeTo: .callout))
                            .monospacedDigit()
                            .opacity(0.8)
                            .fixedSize()
                            .contentTransition(motion.animates ? .numericText() : .identity)
                            .motion(Motion.kindChange, value: counts)
                    }
                    if state.isBranchEnabled {
                        Image(systemName: "chevron.down")
                            .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .heavy))
                            .opacity(0.7)
                    }
                }
                .overlay {
                    Capsule(style: .circular)
                        .fill(Color(espalier: Palette.hover))
                        .opacity(isHovered && state.isBranchEnabled ? 1 : 0)
                        .hoverMotion(isHovered)
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule(style: .circular))
            }
            // Fades the pill while disabled.
            .buttonStyle(.bare(.capsule))
            .disabled(!state.isBranchEnabled)
            .onHover { isHovered = $0 }
            .tooltip(state.branchTooltip(numberFormat) ?? title)
            .accessibilityLabel("Branch: \(title)")
            .accessibilityValue(state.trackingDescription(numberFormat) ?? "")
        }
    }

    /// The branch's color; a detached HEAD is the remotes' slate.
    private var pillColor: NSColor {
        if case .detached = state.branch {
            return PlaceIdentity.remotes.color
        }
        return color ?? Palette.accent
    }

    /// The branch's symbol, or the arc while checking out. The arc gives
    /// way to the symbol with a crossfade over 0.15 s as the checkout ends.
    private var branchSymbol: some View {
        let progress: Double? = if case .checkingOut(_, _, let value) = state.branch { value } else { nil }
        let fade = motion.animates ? AnyTransition.opacity : .identity
        return ZStack {
            if let progress {
                // It turns until git reports how far it has got.
                ArcProgress(.mini, value: progress > 0 ? progress : nil, tint: CandyColors.ink(pillColor))
                    .transition(fade)
            } else {
                Image(systemName: state.branchSystemImage)
                    .font(.system(size: size.symbolSize, weight: .bold))
                    .transition(fade)
            }
        }
        .motion(Motion.leave, value: progress == nil)
    }

    /// The branch's title as one text: a detached HEAD's SHA in the code
    /// font ("On a1b2c3d").
    private func branchText(_ title: String) -> Text {
        guard let sha = state.detachedShortSHA else {
            return Text(title)
        }
        return Text("On \(Text(sha).font(Typography.sha(weight: .bold)))")
    }
}

/// The repository's part of the location control: a plain button with a
/// hover wash.
private struct LocationSegment<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .padding(.leading, Metrics.LocationControl.segmentLeading)
                .padding(.trailing, Metrics.LocationControl.segmentTrailing)
                .frame(maxHeight: .infinity)
                .background {
                    Capsule(style: .circular)
                        .fill(isHovered && isEnabled ? Color(nsColor: Palette.hover) : .clear)
                        .hoverMotion(isHovered)
                        .padding(.vertical, Metrics.LocationControl.inset)
                }
                .contentShape(Capsule(style: .circular))
        }
        // Fades the label while disabled.
        .buttonStyle(.bare(.capsule))
        .onHover { isHovered = $0 }
    }
}

extension Metrics {
    /// The toolbar's location control.
    public enum LocationControl {
        /// How far the branch's pill and the repository's hover wash sit
        /// inside the capsule on every side, so each is concentric with
        /// the capsule's ends: half the capsule's height less the pill's.
        public static var inset: CGFloat {
            (CapsuleButtonAppearance(kind: .quiet, controlSize: .large).capsuleHeight - CandyPillSize.regular.height) / 2
        }
        /// Between the repository and the branch's pill.
        public static let spacing: CGFloat = 2
        /// Before the repository's symbol and after its name, inside its
        /// hover wash.
        public static let segmentLeading: CGFloat = 8
        public static let segmentTrailing: CGFloat = 10
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
            LocationControlView(control, branchColor: context.repository.map(LocationControl.branchColor), fadesInBranch: isBranchSwitch(control), onRepository: {
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
            LocationControl.branchMenu(context: context)
        }
    }

    /// The current branch's color (`BranchColors`), as its row's dot and
    /// its tag in History.
    static func branchColor(_ repository: RepositoryModel) -> NSColor {
        guard let branch = repository.gitState.tip.branch else {
            return Palette.accent
        }
        return BranchColors.of(repository).color(forBranch: branch.name) ?? Palette.accent
    }

    /// The location control's menu, on the current branch.
    @MenuBuilder
    static func branchMenu(context: WindowContext) -> MenuContent {
        if case .branch(let name) = LocationControlState.make(context.app).branch {
            MenuAction(ActionKind.renameBranch.title) { context.actions.perform(.renameBranch(name: name)) }
            MenuAction(ActionKind.copyBranchName.title) { context.actions.perform(.copyBranchName(name: name)) }
            MenuAction(ActionKind.viewBranchOnGitHub.title) { context.actions.perform(.viewBranchOnGitHub(name: name)) }
            MenuAction(ActionKind.viewPullRequestOnGitHub.title) { context.actions.perform(.viewPullRequestOnGitHub(number: nil)) }
            MenuDivider()
            MenuAction(ActionKind.deleteBranch.title) { context.actions.perform(.deleteBranch(name: name)) }
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

// The main window's layout: a detail area with its own inner split, the
// inspector, the toolbar with its search field, the floating capsule and
// toasts, and where the command palette opens. The window is flat
// (`FlatWindowChrome`): the sidebar is opaque, or glass where the theme's
// backdrop is (ChromeBackdrop.swift), and the columns draw the toolbar's
// band. In the floating layout the panes are cards on the backdrop
// (FloatingPanes.swift); in the inset card layout they're in one card on
// it (InsetCard.swift).
//
// The sidebar takes the style Settings ▸ Appearance ▸ Sidebar picks: in the
// hidden style a two-column `NavigationSplitView`, the sidebar's column
// hidden as the window opens; in the icons style the rail at the detail
// area's leading edge (SidebarRail.swift) and no column, so nothing at the
// window's edge drags out. The sidebar's column, the rail, and Commit Info's
// column slide in and out over 0.22 s as the user shows and hides them.

import EspalierCore
import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window's content once the app has loaded.
struct MainWindow: View {
    @Environment(WindowContext.self) private var context
    @Environment(\.motion) private var motion
    /// Whether the rail was last hidden, for the next window.
    @AppStorage(WindowState.sidebarHiddenKey) private var isRailHidden = false

    var body: some View {
        let state = context.state
        let style = context.sidebarStyle
        Group {
            switch style {
            case .hidden:
                NavigationSplitView(columnVisibility: Bindable(state).columnVisibility) {
                    SidebarContainer()
                        .navigationSplitViewColumnWidth(
                            min: Metrics.Column.sidebar.min,
                            ideal: Metrics.Column.sidebar.ideal,
                            max: Metrics.Column.sidebar.max ?? Metrics.Column.sidebar.ideal
                        )
                } detail: {
                    detail
                }
            case .icons:
                detail
            }
        }
        .background {
            WindowDividerStyler()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // The command palette opens across the window, under the toolbar.
        .overlay {
            CommandPaletteAnchor()
        }
        .navigationTitle(context.repository?.record.displayName ?? "Espalier")
        .toolbar(removing: .title)
        .toolbar(id: MainToolbar.identifier) {
            MainToolbar(context: context)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: context.app.selection, initial: true) {
            restorePlace()
        }
        .onChange(of: state.isRailHidden) {
            isRailHidden = state.isRailHidden
        }
        // Either style starts with the column hidden.
        .onChange(of: style) {
            state.columnVisibility = .detailOnly
            state.railPopover = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath).map { $0.path(percentEncoded: false) }
            if !folders.isEmpty {
                context.actions.perform(.addRepositories(paths: folders))
            }
        }
    }

    /// The detail area, after the rail in the icons style, with the
    /// inspector.
    private var detail: some View {
        let state = context.state
        let inspector = inspectorBinding
        return HStack(spacing: 0) {
            if context.sidebarStyle == .icons, !state.isRailHidden {
                SidebarRail()
                    .transition(motion.animates ? AnyTransition.move(edge: .leading) : .identity)
            }
            DetailRouter()
                // The inset card, or its part before Commit Info's.
                .insetCard(inspector.wrappedValue ? .leading : .whole)
                .overlay(alignment: .bottom) {
                    FloatingStatus()
                }
                .sidebarNudge(isSidebarHidden: state.columnVisibility == .detailOnly)
                // The cards follow the sidebar as it shows and hides and
                // keep the window's edge margin once it's hidden; the
                // inspector's card keeps the gap after them.
                .paneMarginsBesideSidebar(beforeInspector: inspector.wrappedValue)
        }
        .toolbarBand()
        .inspector(isPresented: inspector) {
            InspectorColumn()
                .inspectorColumnWidth(
                    min: Metrics.Column.inspector.min,
                    ideal: Metrics.Column.inspector.ideal,
                    max: Metrics.Column.inspector.max ?? Metrics.Column.inspector.ideal
                )
        }
    }

    /// Commit Info shows only in History-like places.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { context.state.isInspectorPresented && context.state.place?.showsCommits == true },
            set: { context.state.isInspectorPresented = $0 }
        )
    }

    /// Selecting a repository shows its last place (Changes the first time);
    /// the place is kept when the window switches worktrees.
    private func restorePlace() {
        if case .repository(let id)? = context.app.selection {
            context.state.select(context.state.lastPlace(for: id), in: id)
        } else {
            context.state.select(nil, in: nil)
        }
    }
}

/// The inspector's column: Commit Info under the toolbar's band, with a
/// hairline on its leading edge; a card on the backdrop in the floating
/// layout, and the inset card's trailing part in the inset card layout.
struct InspectorColumn: View {
    var body: some View {
        InspectorRouter()
            .paneCard(margins: EdgeInsets(
                top: PaneCards.frameMargins.top,
                leading: PaneCards.frameGap,
                bottom: PaneCards.frameMargins.bottom,
                trailing: PaneCards.frameMargins.trailing
            ))
            .insetCard(.trailing)
            .padding(InsetCard.isOn ? InsetCard.inspectorMargins : EdgeInsets())
            .toolbarBand()
            // Below the toolbar, which spans the inspector too.
            .overlay(alignment: .leading) {
                Hairline(.vertical)
                    .opacity(Theme.current.paneLayout.chromeIsBackdrop ? 0 : 1)
            }
    }
}

/// The capsule and toasts, bottom-centered over the detail area. Toasts
/// stack above the capsule; the capsule shows outside Changes, where the
/// operation panel takes its place. The capsule rises in and sinks out as
/// toasts do, and animates only when its kind changes (running, conflicted,
/// interrupted, unsupported): its progress fill eases on its own, and the
/// other updates while it runs draw at once.
struct FloatingStatus: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        // Another repository's capsule shows at once.
        FloatingStatusStack()
            .motionScope(context.repository.map { AnyHashable(ObjectIdentifier($0)) })
    }
}

/// The toasts and the capsule, stacked. The toasts' Undo runs from Edit ▸
/// Undo through the window's undo manager.
private struct FloatingStatusStack: View {
    @Environment(WindowContext.self) private var context
    @Environment(\.motion) private var motion
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let capsule = capsuleContent
        let toastIDs = context.presenter.toasts.map(\.id)
        VStack(spacing: Metrics.Floating.spacing) {
            ToastStack(presenter: context.presenter)
            if let capsule {
                OperationCapsule(capsule) {
                    switch capsule {
                    case .interrupted:
                        context.actions.perform(.showChanges)
                    case .unsupported:
                        context.actions.perform(.openInTerminal(path: nil))
                    case .running, .conflicted:
                        context.actions.perform(.showConflicts)
                    }
                }
                .transition(motion.animates ? Motion.floatingTransition : .identity)
            }
        }
        .padding(.horizontal, Metrics.insetLarge)
        .padding(.bottom, Metrics.Floating.bottomInset)
        .animation(motion.animation(capsule == nil ? Motion.leave : Motion.arrive), value: capsule?.kind)
        .animation(motion.animation(Motion.arrive), value: toastIDs)
        .onAppear {
            context.presenter.undoManager = undoManager
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) {
            context.presenter.undoManager = undoManager
        }
    }

    private var capsuleContent: OperationCapsuleContent? {
        guard let repository = context.repository, repository.isUsable, context.state.place != .changes else {
            return nil
        }
        return OperationCapsuleContent.make(repository, numberFormat: numberFormat)
    }
}

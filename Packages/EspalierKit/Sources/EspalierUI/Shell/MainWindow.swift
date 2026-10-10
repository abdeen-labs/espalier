// The main window's layout: a two-column `NavigationSplitView` (the sidebar
// and a detail area with its own inner split), the inspector, the toolbar
// with its search field, and the floating capsule and toasts. The window is
// flat (`FlatWindowChrome`): the sidebar is opaque and the columns draw the
// toolbar's band.

import EspalierCore
import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window's content once the app has loaded.
struct MainWindow: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        @Bindable var state = context.state
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarContainer()
                .navigationSplitViewColumnWidth(
                    min: Metrics.Column.sidebar.min,
                    ideal: Metrics.Column.sidebar.ideal,
                    max: Metrics.Column.sidebar.max ?? Metrics.Column.sidebar.ideal
                )
        } detail: {
            DetailRouter()
                .overlay(alignment: .bottom) {
                    FloatingStatus()
                }
                .toolbarBand()
                .inspector(isPresented: inspectorBinding) {
                    InspectorRouter()
                        .toolbarBand()
                        .overlay(alignment: .leading) {
                            Hairline(.vertical)
                                .ignoresSafeArea()
                        }
                        .inspectorColumnWidth(
                            min: Metrics.Column.inspector.min,
                            ideal: Metrics.Column.inspector.ideal,
                            max: Metrics.Column.inspector.max ?? Metrics.Column.inspector.ideal
                        )
                }
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
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath).map { $0.path(percentEncoded: false) }
            if !folders.isEmpty {
                context.actions.perform(.addRepositories(paths: folders))
            }
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
        return OperationCapsuleContent.make(repository)
    }
}

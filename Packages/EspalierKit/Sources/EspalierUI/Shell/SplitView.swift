// The detail area's inner split: an `NSSplitView` whose divider is saved per
// kind of place, so the Changes column and the graph each keep their own
// width. A place's split floats its panes as cards in the floating layout
// (FloatingPanes.swift).

import AppKit
import SwiftUI

/// Two panes side by side, the divider saved per kind of place.
///
/// The leading pane keeps its width as the window resizes, within its
/// column's limits; the trailing pane takes the rest and is never narrower
/// than its minimum (the diff's, or a commit's files and diff). Each pane is
/// hosted in its own `NSHostingView` with the window's environment
/// (`WindowContext`, dates, avatars).
public struct SplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    private let autosaveName: String
    private let column: Metrics.ColumnWidth
    private let trailingMinimum: CGFloat
    /// Whether it holds a place's panes (cards in the floating layout).
    private var holdsPanes = false
    private let leading: Leading
    private let trailing: Trailing
    @Environment(WindowContext.self) private var windowContext: WindowContext?

    public init(_ kind: PlaceKind, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(
            autosaveName: kind.splitAutosaveName,
            leadingColumn: kind.leadingColumn,
            trailingMinimum: kind.trailingMinimum,
            leading: leading,
            trailing: trailing
        )
        holdsPanes = true
    }

    /// A split inside a place (History's commit file list beside its diff),
    /// its divider saved under `autosaveName`.
    public init(
        autosaveName: String,
        leadingColumn: Metrics.ColumnWidth,
        trailingMinimum: CGFloat = Metrics.Column.diffMinimum,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.autosaveName = autosaveName
        column = leadingColumn
        self.trailingMinimum = trailingMinimum
        self.leading = leading()
        self.trailing = trailing()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(column: column, trailingMinimum: trailingMinimum)
    }

    public func makeNSView(context: Context) -> NSSplitView {
        let splitView = PaneSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.holdsPanes = holdsPanes
        splitView.delegate = context.coordinator

        let leadingHost = NSHostingView(rootView: bridged(AnyView(leading), context.environment))
        let trailingHost = NSHostingView(rootView: bridged(AnyView(trailing), context.environment))
        for host in [leadingHost, trailingHost] {
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
        }
        let width = column.ideal
        leadingHost.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        trailingHost.frame = CGRect(x: width + 1, y: 0, width: trailingMinimum, height: 400)
        let leadingPane = PaneCardView(content: leadingHost)
        let trailingPane = PaneCardView(content: trailingHost)
        splitView.addArrangedSubview(leadingPane)
        splitView.addArrangedSubview(trailingPane)
        splitView.updateLayout()
        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        context.coordinator.leadingPane = leadingPane
        // AppKit saves dividers only in the standard defaults: a window
        // whose app keeps its state elsewhere (tests) saves none, and
        // starts at the ideal width.
        let savesDivider = windowContext?.persistsUIState ?? true
        if savesDivider {
            context.coordinator.needsInitialPosition = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") == nil
            splitView.autosaveName = autosaveName
        } else {
            context.coordinator.needsInitialPosition = true
        }
        return splitView
    }

    public func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingHost?.rootView = bridged(AnyView(leading), context.environment)
        context.coordinator.trailingHost?.rootView = bridged(AnyView(trailing), context.environment)
        (splitView as? PaneSplitView)?.updateLayout()
    }

    /// The pane's content with the window's environment, which doesn't
    /// cross into a new hosting view on its own.
    private func bridged(_ content: AnyView, _ environment: EnvironmentValues) -> AnyView {
        AnyView(content.modifier(EnvironmentBridge(values: environment, windowContext: windowContext, isInPaneCard: holdsPanes || environment.isInPaneCard)))
    }

    /// Keeps the panes within their limits.
    public final class Coordinator: NSObject, NSSplitViewDelegate {
        let column: Metrics.ColumnWidth
        /// The narrowest the trailing pane gets.
        let trailingMinimum: CGFloat
        weak var leadingHost: NSHostingView<AnyView>?
        weak var trailingHost: NSHostingView<AnyView>?
        /// The leading pane's view in the split, when it isn't the host
        /// itself (the card that holds it).
        weak var leadingPane: NSView?
        var needsInitialPosition = false
        /// Set while the coordinator moves the divider itself, whose resize
        /// comes back here.
        private var isPlacingDivider = false

        init(column: Metrics.ColumnWidth, trailingMinimum: CGFloat = Metrics.Column.diffMinimum) {
            self.column = column
            self.trailingMinimum = trailingMinimum
        }

        /// The room the panes' cards keep inside their frames, on both
        /// sides, while floating: added to the limits so a pane's content
        /// is as wide as when flat.
        private func cardRoom(_ splitView: NSSplitView) -> CGFloat {
            (splitView as? PaneSplitView)?.floats == true ? 2 * PaneCards.inset : 0
        }

        public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, column.min + cardRoom(splitView))
        }

        public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let room = cardRoom(splitView)
            let available = splitView.bounds.width - trailingMinimum - room - splitView.dividerThickness
            let maximum = column.max.map { min($0 + room, available) } ?? available
            return max(min(proposedMaximumPosition, maximum), column.min + room)
        }

        public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            // The leading pane keeps its width; the trailing pane takes the
            // window's growth and shrinkage.
            view !== (leadingPane ?? leadingHost)
        }

        public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        /// Floating, the whole gap between the cards drags the divider,
        /// the room inside each card's frame too.
        public func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            guard (splitView as? PaneSplitView)?.floats == true else {
                return proposedEffectiveRect
            }
            return proposedEffectiveRect.insetBy(dx: -PaneCards.inset, dy: 0)
        }

        /// Places the divider at the leading pane's ideal width on the first
        /// layout with room for it, and whenever the leading pane is
        /// narrower than its minimum. AppKit restores a saved divider as it
        /// was saved, and one saved during a layout made while the window
        /// was still being built can leave the pane 0 wide for good.
        public func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isPlacingDivider,
                  let splitView = notification.object as? NSSplitView else {
                return
            }
            let room = cardRoom(splitView)
            guard splitView.bounds.width > column.min + room + splitView.dividerThickness else {
                return
            }
            let tooNarrow = (leadingPane ?? leadingHost).map { $0.frame.width < column.min + room } ?? false
            guard needsInitialPosition || tooNarrow else {
                return
            }
            needsInitialPosition = false
            isPlacingDivider = true
            defer { isPlacingDivider = false }
            let available = splitView.bounds.width - trailingMinimum - room - splitView.dividerThickness
            splitView.setPosition(max(min(column.ideal + room, available), column.min + room), ofDividerAt: 0)
        }
    }
}

/// Carries the window's environment into a hosted pane.
struct EnvironmentBridge: ViewModifier {
    let values: EnvironmentValues
    let windowContext: WindowContext?
    /// Whether the pane is a card (in the floating layout), or in one.
    var isInPaneCard = false

    func body(content: Content) -> some View {
        content
            .environment(windowContext)
            .environment(\.isInPaneCard, isInPaneCard)
            .environment(\.dateTimeFormatting, values.dateTimeFormatting)
            .environment(\.avatarLoader, values.avatarLoader)
            .environment(\.timeZone, values.timeZone)
            .environment(\.locale, values.locale)
            .environment(\.calendar, values.calendar)
    }
}

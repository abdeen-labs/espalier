// The detail area's inner split: an `NSSplitView` whose divider is saved per
// kind of place, so the Changes column and the graph each keep their own
// width.

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
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
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
        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)
        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        // AppKit saves dividers only in the standard defaults: a window
        // whose app keeps its state elsewhere (tests) and snapshots save
        // none, and start at the ideal width.
        let savesDivider = context.environment.savesSplitDividers && (windowContext?.persistsUIState ?? true)
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
    }

    /// The pane's content with the window's environment, which doesn't
    /// cross into a new hosting view on its own.
    private func bridged(_ content: AnyView, _ environment: EnvironmentValues) -> AnyView {
        AnyView(content.modifier(EnvironmentBridge(values: environment, windowContext: windowContext)))
    }

    /// Keeps the panes within their limits.
    public final class Coordinator: NSObject, NSSplitViewDelegate {
        let column: Metrics.ColumnWidth
        /// The narrowest the trailing pane gets.
        let trailingMinimum: CGFloat
        weak var leadingHost: NSHostingView<AnyView>?
        weak var trailingHost: NSHostingView<AnyView>?
        var needsInitialPosition = false
        /// Set while the coordinator moves the divider itself, whose resize
        /// comes back here.
        private var isPlacingDivider = false

        init(column: Metrics.ColumnWidth, trailingMinimum: CGFloat = Metrics.Column.diffMinimum) {
            self.column = column
            self.trailingMinimum = trailingMinimum
        }

        public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, column.min)
        }

        public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let available = splitView.bounds.width - trailingMinimum - splitView.dividerThickness
            let maximum = column.max.map { min($0, available) } ?? available
            return max(min(proposedMaximumPosition, maximum), column.min)
        }

        public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            // The leading pane keeps its width; the trailing pane takes the
            // window's growth and shrinkage.
            view !== leadingHost
        }

        public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        /// Places the divider at the leading pane's ideal width on the first
        /// layout with room for it, and whenever the leading pane is
        /// narrower than its minimum. AppKit restores a saved divider as it
        /// was saved, and one saved during a layout made while the window
        /// was still being built can leave the pane 0 wide for good.
        public func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isPlacingDivider,
                  let splitView = notification.object as? NSSplitView,
                  splitView.bounds.width > column.min + splitView.dividerThickness else {
                return
            }
            let tooNarrow = leadingHost.map { $0.frame.width < column.min } ?? false
            guard needsInitialPosition || tooNarrow else {
                return
            }
            needsInitialPosition = false
            isPlacingDivider = true
            defer { isPlacingDivider = false }
            let available = splitView.bounds.width - trailingMinimum - splitView.dividerThickness
            splitView.setPosition(max(min(column.ideal, available), column.min), ofDividerAt: 0)
        }
    }
}

extension EnvironmentValues {
    /// Whether splits save their dividers (`NSSplitView.autosaveName`):
    /// snapshots turn it off, so no saved divider changes what they draw.
    @Entry public var savesSplitDividers = true
}

/// Carries the window's environment into a hosted pane.
struct EnvironmentBridge: ViewModifier {
    let values: EnvironmentValues
    let windowContext: WindowContext?

    func body(content: Content) -> some View {
        content
            .environment(windowContext)
            .environment(\.fixedNow, values.fixedNow)
            .environment(\.dateTimeFormatting, values.dateTimeFormatting)
            .environment(\.avatarLoader, values.avatarLoader)
            .environment(\.savesSplitDividers, values.savesSplitDividers)
            .environment(\.showsDelayedContentImmediately, values.showsDelayedContentImmediately)
            .environment(\.timeZone, values.timeZone)
            .environment(\.locale, values.locale)
            .environment(\.calendar, values.calendar)
    }
}

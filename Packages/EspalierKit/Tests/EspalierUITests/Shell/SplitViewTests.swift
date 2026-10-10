// The detail area's inner split. A divider AppKit restores from a bad save
// would leave the Changes column 0 wide for good; the split puts it back.
// History's lists leave a commit's files and diff their room.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A leading pane AppKit restored too narrow.
enum RestoredPane: Sendable {
    /// The Changes list, 0 wide.
    case changesListZeroWide
    /// The graph list, 40 points narrower than its minimum.
    case graphListBelowMinimum

    @MainActor var column: Metrics.ColumnWidth {
        switch self {
        case .changesListZeroWide: Metrics.Column.changesFileList
        case .graphListBelowMinimum: Metrics.Column.graphList
        }
    }

    @MainActor var leadingWidth: CGFloat {
        switch self {
        case .changesListZeroWide: 0
        case .graphListBelowMinimum: column.min - 40
        }
    }
}

@Suite("Split view") @MainActor
struct SplitViewTests {
    /// A split as `SplitView` builds it, with the leading pane `leadingWidth`
    /// wide, as AppKit leaves it after restoring a saved divider.
    private func split(
        width: CGFloat,
        leadingWidth: CGFloat,
        column: Metrics.ColumnWidth,
        trailingMinimum: CGFloat = Metrics.Column.diffMinimum
    ) -> (NSSplitView, NSView, SplitView<EmptyView, EmptyView>.Coordinator) {
        let coordinator = SplitView<EmptyView, EmptyView>.Coordinator(column: column, trailingMinimum: trailingMinimum)
        let splitView = NSSplitView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let leading = NSHostingView(rootView: AnyView(EmptyView()))
        let trailing = NSHostingView(rootView: AnyView(EmptyView()))
        splitView.addArrangedSubview(leading)
        splitView.addArrangedSubview(trailing)
        leading.frame = CGRect(x: 0, y: 0, width: leadingWidth, height: 600)
        trailing.frame = CGRect(
            x: leadingWidth + splitView.dividerThickness,
            y: 0,
            width: width - leadingWidth - splitView.dividerThickness,
            height: 600
        )
        coordinator.leadingHost = leading
        coordinator.trailingHost = trailing
        splitView.delegate = coordinator
        return (splitView, leading, coordinator)
    }

    private func didResize(_ splitView: NSSplitView, _ coordinator: SplitView<EmptyView, EmptyView>.Coordinator) {
        coordinator.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView))
    }

    @Test("a leading pane restored too narrow goes back to its ideal width", arguments: [
        NamedCase("a leading pane restored 0 wide goes back to its ideal width", RestoredPane.changesListZeroWide),
        NamedCase("a leading pane restored narrower than its minimum goes back to its ideal width", RestoredPane.graphListBelowMinimum),
    ])
    func restoredTooNarrow(_ testCase: NamedCase<RestoredPane>) {
        let column = testCase.value.column
        let (splitView, leading, coordinator) = split(width: 1335, leadingWidth: testCase.value.leadingWidth, column: column)
        didResize(splitView, coordinator)
        #expect(leading.frame.width == column.ideal)
    }

    @Test("a leading pane within its limits keeps the width the user gave it")
    func keepsUsersWidth() {
        let column = Metrics.Column.changesFileList
        let (splitView, leading, coordinator) = split(width: 1335, leadingWidth: column.min + 30, column: column)
        didResize(splitView, coordinator)
        #expect(leading.frame.width == column.min + 30)
    }

    @Test("the first layout with room places the divider at the ideal width, once")
    func initialPosition() {
        let column = Metrics.Column.changesFileList
        let (splitView, leading, coordinator) = split(width: 1335, leadingWidth: column.min + 30, column: column)
        coordinator.needsInitialPosition = true
        didResize(splitView, coordinator)
        #expect(leading.frame.width == column.ideal)
        #expect(!coordinator.needsInitialPosition)
    }

    @Test("at the default window, History's list leaves a commit's files and diff their room", arguments: [
        NamedCase("the simple list leaves a commit's files and diff their room", PlaceKind.simpleHistory),
        NamedCase("the graph leaves a commit's files and diff their room", PlaceKind.graphHistory),
    ])
    func historyDetailsFit(_ testCase: NamedCase<PlaceKind>) {
        let kind = testCase.value
        // The detail area beside the sidebar at its ideal width.
        let width = Metrics.Window.defaultWidth - Metrics.Column.sidebar.ideal - 1
        let (splitView, leading, coordinator) = split(
            width: width,
            leadingWidth: 0,
            column: kind.leadingColumn,
            trailingMinimum: kind.trailingMinimum
        )
        coordinator.needsInitialPosition = true
        didResize(splitView, coordinator)
        #expect(leading.frame.width == kind.leadingColumn.ideal)
        let details = width - leading.frame.width - splitView.dividerThickness
        #expect(details >= Metrics.Column.commitFileList.ideal + splitView.dividerThickness + Metrics.Column.diffMinimum)
        // Dragging the divider leaves the details their files and diff.
        let maximum = coordinator.splitView(splitView, constrainMaxCoordinate: width, ofSubviewAt: 0)
        #expect(width - maximum - splitView.dividerThickness >= Metrics.Column.commitDetailMinimum)
    }

    @Test("a split too narrow for the leading pane's minimum is left as it is, without looping")
    func tooNarrowToFix() {
        let column = Metrics.Column.changesFileList
        let (splitView, leading, coordinator) = split(width: column.min - 20, leadingWidth: 0, column: column)
        coordinator.needsInitialPosition = true
        didResize(splitView, coordinator)
        #expect(leading.frame.width == 0)
        #expect(coordinator.needsInitialPosition)
    }
}

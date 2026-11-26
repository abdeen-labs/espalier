// The shelf on the window's backdrop: six pieces of work that need the user
// and three in progress under Needs You (the compact tabs after a hairline)
// and under Recent Activity, "23 quiet" at the end; more tabs than fit, one
// open far along; a quiet open piece of work beside one other; and long
// repository and branch names. And the toolbar's Home pieces: the Home
// button before the location control, the toolbar on Home (the "Home"
// capsule and the jump field), and the toolbar with Home off.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Shelf", .captures, .hangGuard(minutes: 5)) @MainActor
struct ShelfCaptures {
    private let area = "Shelf"
    private let format = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

    /// The shelf for `builder` under `arrangement`, `width` wide, under a
    /// band as the toolbar leaves above it.
    private func strip(_ builder: WorkSampleBuilder, _ arrangement: RepositoryArrangement, width: CGFloat = 1_240) -> some View {
        let content = ShelfContent.make(builder.shelf(arrangement), arrangement: arrangement, format: format)
        return WorkShelfView(content)
            .padding(.top, Metrics.insetSmall)
            .frame(width: width)
            .background(Color(nsColor: Theme.current.backdrop))
    }

    @Test("Needs You: six full tabs with their marks, three compact ones after a hairline, and 23 quiet")
    func needsYou() {
        capture(strip(.sample(), .needsYou), named: "needs-you", area: area)
    }

    @Test("Recent Activity: the same work, every tab a full one in the order of its activity")
    func recentActivity() {
        capture(strip(.sample(), .recentActivity), named: "recent-activity", area: area)
    }

    @Test("more tabs than fit: they scroll, fading at the end with more beyond it")
    func overflow() {
        capture(strip(.sample(), .recentActivity, width: 720), named: "overflow", area: area)
    }

    @Test("a quiet open piece of work beside one other")
    func quietOpen() {
        var builder = WorkSampleBuilder()
        builder.open = builder.add("harbor", branch: "main", .quiet)
        builder.add("pier-api", branch: "agent/rate-limits", .checksFailing, minutesAgo: 3, unseen: true)
        for index in 1...4 {
            builder.add("quiet-\(index)", .quiet)
        }
        capture(strip(builder, .needsYou, width: 900), named: "quiet-open", area: area)
    }

    @Test("long repository and branch names, and a detached HEAD")
    func longNames() {
        var builder = WorkSampleBuilder()
        builder.open = builder.add("harbor-tide-forecasting-service", branch: "feature/offline-tide-charts-with-cache", .changes(14, ahead: 12), minutesAgo: 1)
        builder.add("a-repository-with-a-very-long-name", branch: "agent/rewrite-the-onboarding-flow-from-scratch", .rebaseStopped(conflicts: 3), minutesAgo: 2, unseen: true)
        builder.add("lighthouse", branch: "x", .changes(1_204), minutesAgo: 3)
        capture(strip(builder, .recentActivity, width: 900), named: "long-names", area: area)
    }

    // MARK: Toolbar

    /// A toolbar row, as the window's toolbar lays it out, on the backdrop.
    private func toolbar<Leading: View, Trailing: View>(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: Metrics.insetMedium)
            trailing()
            Button {} label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.icon)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(width: 1_000, height: Metrics.Toolbar.height - 1)
        .background(Color(nsColor: Theme.current.backdrop))
    }

    private static let location = LocationControlState(
        repository: .repository(name: "harbor", path: "/Users/joe/Developer/harbor"),
        branch: .branch(name: "feature/charts")
    )

    @Test("the toolbar: the Home button before the location control")
    func toolbarHomeButton() {
        capture(toolbar {
            Button {} label: {
                Image(systemName: "house")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(QuietRoundButtonStyle())
            LocationControlView(Self.location)
        } trailing: {
            CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                .controlSize(.large)
                .frame(width: Metrics.Toolbar.searchWidth)
                .environment(\.searchFieldIsRaised, PaneCards.floats)
        }, named: "toolbar-home-button", area: area)
    }

    @Test("the toolbar on Home: the Home capsule and the jump field")
    func toolbarOnHome() {
        capture(toolbar {
            HomeLocationView()
        } trailing: {
            JumpFieldView(keyCap: "⌘K")
                .environment(\.searchFieldIsRaised, PaneCards.floats)
        }, named: "toolbar-on-home", area: area)
    }

    @Test("the toolbar with Home off: the location control first, as before")
    func toolbarHomeOff() {
        capture(toolbar {
            LocationControlView(Self.location)
        } trailing: {
            CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                .controlSize(.large)
                .frame(width: Metrics.Toolbar.searchWidth)
                .environment(\.searchFieldIsRaised, PaneCards.floats)
        }, named: "toolbar-home-off", area: area)
    }
}

// The toolbar's controls: the sync button in each of its states (a push's
// progress on its blue capsule, a fetch's before git reports a value, the
// counts, a diverged pull, a background failure, ...), Stop beside it once
// a push or fetch has run a while, the toolbar while the selected
// repository loads (nothing where the last fetch and the button were, in
// the width they had), and the location control in each of its states.

import AppKit
import EspalierCore
import Foundation
import GitKit
import Observation
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Toolbar", .captures, .hangGuard(minutes: 5)) @MainActor
struct ToolbarCaptures {
    /// The sync button's states, fetched as long before now as before the
    /// fixtures' fixed date.
    nonisolated static let syncStates: [String] = UIFixtures.syncStates.map(\.name)

    private static func syncState(_ name: String) throws -> SyncButtonState {
        var state = try #require(UIFixtures.syncStates.first { $0.name == name }?.state)
        state.lastFetched = state.lastFetched.map { Date().addingTimeInterval($0.timeIntervalSince(UIFixtures.now)) }
        return state
    }

    @Test("the sync button", arguments: ToolbarCaptures.syncStates)
    func syncButton(name: String) throws {
        let state = try Self.syncState(name)
        capture(SyncButtonView(state).padding(Metrics.insetMedium), named: name, area: "SyncButton")
    }

    @Test("the sync button's menu with other remotes: the alternatives, then Also Push To", arguments: ["8-push-also", "9-fetch-also"])
    func syncMenu(name: String) throws {
        let state = try Self.syncState(name)
        let content = SyncButtonView(state).menu(detail: state.detail(now: Date()))
        capture(MenuCard(level: MenuLevel(content: content)), named: "\(name)-menu", area: "SyncButton")
    }

    @Test("the sync group once Stop shows, in the last fetch's place", arguments: ["1-progress", "1-progress-starting"])
    func syncGroupWithStop(name: String) throws {
        var state = try Self.syncState(name)
        state.offersStop = true
        capture(SyncButtonGroup(state).padding(Metrics.insetMedium), named: "\(name)-stop", area: "SyncButton")
    }

    /// The state the loading toolbar's group shows.
    @MainActor @Observable
    final class GroupState {
        var state: SyncButtonState

        init(_ state: SyncButtonState) {
            self.state = state
        }
    }

    /// A toolbar row: the location control, the search field, the sync
    /// group, and More.
    private struct ToolbarRow: View {
        let location: LocationControlState
        let group: GroupState

        var body: some View {
            HStack(spacing: 10) {
                LocationControlView(location)
                Spacer(minLength: Metrics.insetMedium)
                CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                    .controlSize(.large)
                    .frame(width: Metrics.Toolbar.searchWidth)
                SyncButtonGroup(group.state)
                Button {} label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.icon)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(height: Metrics.Toolbar.height - 1)
        }
    }

    @Test("the toolbar while the selected repository loads: nothing where the last fetch and the button were")
    func loading() async throws {
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: Date().addingTimeInterval(-5 * 60))
        let before = LocationControlState(repository: .repository(name: "meridian", path: "/Users/joe/Developer/meridian"), branch: .branch(name: "main"))
        let now = LocationControlState(repository: .repository(name: "forecast-kit", path: "/Users/joe/Developer/forecast-kit"), branch: .hidden)
        for appearance in CaptureAppearance.allCases {
            // The second row showed the fetch before the selection changed,
            // then loads.
            let loading = GroupState(fetch)
            let stage = SettlingStage(
                VStack(spacing: 0) {
                    ToolbarRow(location: before, group: GroupState(fetch))
                    Hairline()
                    ToolbarRow(location: now, group: loading)
                    Hairline()
                }
                .frame(width: 900),
                appearance: appearance
            )
            await stage.settle()
            loading.state = SyncButtonState(kind: .loading)
            await stage.settle()
            let image = stage.image
            stage.close()
            capture(named: "loading", area: "SyncButton", appearances: [appearance]) { _ in image }
        }
    }

    @Test("the location control", arguments: UIFixtures.locationStates.map(\.name))
    func locationControl(name: String) throws {
        let state = try #require(UIFixtures.locationStates.first { $0.name == name }?.state)
        capture(LocationControlView(state).padding(Metrics.insetMedium), named: name, area: "LocationControl")
    }

    /// A feature branch.
    private static let featureLocation = LocationControlState(
        repository: .repository(name: "harbor", path: "/Users/joe/Developer/harbor"),
        branch: .branch(name: "feature/charts")
    )

    @Test("the location control on a feature branch, in the branch's color")
    func locationControlColor() {
        capture(
            LocationControlView(Self.featureLocation, branchColor: PlaceIdentity.grape).padding(Metrics.insetMedium),
            named: "branch-color",
            area: "LocationControl"
        )
    }

    @Test("Changes | History: Changes with its count, History, conflicts, and another place")
    func placeTabs() {
        let tabs = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            PlaceTabs(selection: .changes, changes: ChangesPlaceRowContent(changedFileCount: 3, hasConflicts: false))
            PlaceTabs(selection: .history, changes: ChangesPlaceRowContent(changedFileCount: 12, hasConflicts: false))
            PlaceTabs(selection: .changes, changes: ChangesPlaceRowContent(changedFileCount: 2, hasConflicts: true))
            PlaceTabs(selection: .stash(sha: "a1b2c3d"), changes: ChangesPlaceRowContent(changedFileCount: 0, hasConflicts: false))
        }
        .padding(Metrics.insetMedium)
        .background(Color(nsColor: Palette.sidebar))
        capture(tabs, named: "tabs", area: "PlaceSwitcher")
    }

    @Test("the sync group: the last fetch beside the button", arguments: ["9-fetch", "8-push", "7-pull-diverged"])
    func syncGroup(name: String) throws {
        let state = try Self.syncState(name)
        capture(SyncButtonGroup(state).padding(Metrics.insetMedium), named: "\(name)-group", area: "SyncButton")
    }
}

private extension PlaceIdentity {
    /// A feature branch's color.
    static var grape: NSColor {
        PlaceIdentity.stashes.color
    }
}

// The design system's components, each in light and dark: capsule buttons
// in their three styles and four heights, pressed and disabled; the split
// button; the search field; the segmented control; chips, key caps, status
// badges, icon circles, and repository badges; the arc and the progress
// bar; flat surfaces; and the window's pieces, the sidebar and the
// toolbar.

import AppKit
import EspalierCore
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Components") @MainActor
struct ComponentSnapshotTests {
    private let area = "Components"

    // MARK: Buttons

    @Test("capsule buttons: quiet, prominent, and secondary at each height, pressed and disabled")
    func buttons() {
        let sizes: [ControlSize] = [.small, .regular, .large, .extraLarge]
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            ForEach(Array(sizes.enumerated()), id: \.offset) { _, size in
                HStack(spacing: Metrics.insetMedium) {
                    Button("Quiet") {}
                        .buttonStyle(.quiet)
                    Button {} label: {
                        Label("Push origin", systemImage: "arrow.up")
                    }
                    .buttonStyle(.prominent)
                    Button("Cancel") {}
                        .buttonStyle(.secondary)
                    Button {} label: {
                        Label("Open in Xcode", systemImage: "hammer")
                    }
                    .buttonStyle(.quiet)
                }
                .controlSize(size)
            }
            HStack(spacing: Metrics.insetMedium) {
                CapsuleButtonBody(kind: .quiet, label: Text("Pressed"), isPressed: true)
                CapsuleButtonBody(kind: .prominent, label: Text("Pressed"), isPressed: true)
                CapsuleButtonBody(kind: .secondary, label: Text("Pressed"), isPressed: true)
                Button("Disabled") {}
                    .buttonStyle(.quiet)
                    .disabled(true)
                Button("Continue") {}
                    .buttonStyle(.prominent)
                    .disabled(true)
            }
            .controlSize(.regular)
            HStack(spacing: Metrics.insetMedium) {
                Button {} label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.icon)
                Button {} label: {
                    Label("Commit Info", systemImage: "info.circle")
                }
                .buttonStyle(.icon)
            }
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "buttons", area: area)
    }

    @Test("the split button: prominent with a count, and quiet")
    func splitButton() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            SplitCapsuleButton(.prominent, action: {}) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Push origin")
                    Text("↑1")
                        .font(Typography.aheadCount)
                }
            } menu: {
                Button("Fetch origin") {}
            }
            SplitCapsuleButton(.quiet, action: {}) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.text2)
                    Text("Pull origin")
                }
            } menu: {
                Button("Fetch origin") {}
            }
        }
        .controlSize(.large)
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "splitButton", area: area)
    }

    // MARK: Fields and segmented controls

    @Test("the search field: empty with its shortcut, and filled")
    func searchField() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                .controlSize(.large)
            CapsuleSearchField("Search Commits", text: .constant("forecast"), keyCap: "⌥⌘F")
                .controlSize(.large)
            CapsuleSearchField("Filter", text: .constant(""), systemImage: "line.3.horizontal.decrease")
        }
        .frame(width: Metrics.Toolbar.searchWidth)
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "searchField", area: area)
    }

    @Test("the segmented control: Simple | Graph with symbols, Unified | Split, and disabled")
    func segmentedControl() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            CapsuleSegmentedControl("History Mode", selection: .constant("simple"), segments: [
                CapsuleSegment("Simple", systemImage: "list.bullet", value: "simple"),
                CapsuleSegment("Graph", systemImage: "point.3.connected.trianglepath.dotted", value: "graph"),
            ])
            CapsuleSegmentedControl("Diff Layout", selection: .constant("split"), segments: [
                CapsuleSegment("Unified", value: "unified"),
                CapsuleSegment("Split", value: "split"),
            ])
            CapsuleSegmentedControl("Diff Layout", selection: .constant("unified"), segments: [
                CapsuleSegment("Unified", value: "unified"),
                CapsuleSegment("Split", value: "split"),
            ])
            .disabled(true)
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "segmentedControl", area: area)
    }

    // MARK: Chips and badges

    @Test("status badges, key caps, the ID chip, icon circles, and repository badges")
    func chips() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetSmall) {
                ForEach(FileStatusKind.allCases, id: \.self) { kind in
                    StatusGlyph(kind)
                }
                KeyCap("⌘F")
                KeyCap("⇧⌘R")
                KeyCap("esc")
                MonoChip("5b7e1d4") {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.text3)
                }
            }
            HStack(spacing: Metrics.insetSmall) {
                IconCircle("sparkles", tint: .accentColor)
                IconCircle("person.2")
                IconCircle("arrow.triangle.merge", size: 26)
                IconCircle("checkmark", size: 40, tint: Color(espalier: Palette.add))
                RepositoryBadge(title: "meridian")
                RepositoryBadge(title: "meridian-api")
                RepositoryBadge(title: "design-tokens")
                RepositoryBadge(title: "forecast-kit")
                RepositoryBadge(title: ".dotfiles")
                SectionLabel("Branches", count: 5)
            }
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "chips", area: area)
    }

    @Test("a copy button after a copy: its check, for a moment, in the chip's room")
    func copiedCheck() {
        let view = HStack(spacing: Metrics.insetMedium) {
            MonoChip("5b7e1d4") {
                CommitSHACopyButton(sha: "5b7e1d4f0c2a", showsCheck: true)
            }
            MonoChip("5b7e1d4") {
                CommitSHACopyButton(sha: "5b7e1d4f0c2a")
            }
        }
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "copiedCheck", area: area)
    }

    @Test("progress: the arc at each size, turning and filling, beside text and on the prominent capsule; the bar sweeping and filling")
    func progress() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetLarge) {
            HStack(spacing: Metrics.insetLarge) {
                ArcProgress(.mini)
                ArcProgress(.small)
                ArcProgress(.large)
                ArcProgress(.mini, value: 0.4)
                ArcProgress(.small, value: 0.4)
                ArcProgress(.large, value: 0.7)
            }
            HStack(spacing: Metrics.insetSmall) {
                ArcProgress(.small)
                Text("Waiting for you to authorize Espalier…")
                    .foregroundStyle(.text2)
            }
            HStack(spacing: Metrics.insetSmall) {
                ArcProgress(.small, tint: .white)
                Text("Committing 3 Files…")
            }
            .capsuleChrome(.prominent)
            VStack(spacing: Metrics.insetMedium) {
                CapsuleProgressBar(value: nil)
                CapsuleProgressBar(value: 0.42)
                CapsuleProgressBar(value: 1)
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "progress", area: area)
    }

    @Test("flat surfaces: a floating capsule with its shadow, and a card with its ring alone")
    func surfaces() {
        let view = VStack(alignment: .leading, spacing: Metrics.insetLarge + 4) {
            HStack(spacing: Metrics.insetMedium) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(espalier: Palette.success))
                Text("Committed “Show hourly forecast”")
                Button {} label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.secondary)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: Metrics.Floating.height)
            .floatingSurface()
            VStack(alignment: .leading, spacing: 4) {
                Text("Show hourly forecast for the next 24 hours")
                    .font(Typography.row.weight(.semibold))
                Text("Requests hourly data with the daily forecast.")
                    .font(Typography.secondary)
                    .foregroundStyle(.text2)
            }
            .padding(11)
            .frame(width: 320, alignment: .leading)
            .cardSurface()
        }
        .padding(28)
        assertSnapshot(view, named: "surfaces", area: area)
    }

    // MARK: The window's pieces

    /// A sidebar from its value-driven rows.
    private func sidebar(selection: SidebarPlace?) -> some View {
        List {
            PlacesSectionRows(changes: ChangesPlaceRowContent(changedFileCount: 7, hasConflicts: false), selection: selection)
            Section {
                BranchRow(BranchRowContent(ref: "refs/heads/feature/hourly-forecast", name: "feature/hourly-forecast", isCurrent: true, tracking: .aheadBehind(ahead: 1, behind: 0)))
                    .sidebarRow(.branch(ref: "refs/heads/feature/hourly-forecast"))
                BranchRow(BranchRowContent(ref: "refs/heads/main", name: "main", tracking: .aheadBehind(ahead: 0, behind: 0), isDefault: true))
                    .sidebarRow(.branch(ref: "refs/heads/main"))
                BranchRow(BranchRowContent(ref: "refs/heads/fix/locale-units", name: "fix/locale-units"), dotColor: TrackPalette.Resolved().color(forTrack: 1))
                    .sidebarRow(.branch(ref: "refs/heads/fix/locale-units"))
                BranchRow(BranchRowContent(ref: "refs/heads/spike/widget-intents", name: "spike/widget-intents", tracking: .aheadBehind(ahead: 0, behind: 11)), dotColor: TrackPalette.Resolved().color(forTrack: 2))
                    .sidebarRow(.branch(ref: "refs/heads/spike/widget-intents"))
            } header: {
                SidebarSectionHeader("Branches") {
                    Image(systemName: "plus")
                }
            }
            Section {
                PullRequestRow(content: PullRequestRowContent(number: 216, title: "Hourly forecast in the widget", author: "maya", created: UIFixtures.minutesAgo(90), checks: .success))
                    .sidebarRow(.pullRequest(number: 216))
                PullRequestRow(content: PullRequestRowContent(number: 217, title: "Cache forecasts for 10 minutes", author: "leo", created: UIFixtures.minutesAgo(40), checks: .pending))
                    .sidebarRow(.pullRequest(number: 217))
                PullRequestRow(content: PullRequestRowContent(number: 211, title: "Air quality index card", author: "sam", created: UIFixtures.minutesAgo(400), isDraft: true))
                    .sidebarRow(.pullRequest(number: 211))
            } header: {
                SidebarSectionHeader("Pull Requests")
            }
            Section {
                TagRow(content: TagRowContent(name: "v2.4.0", isWaitingToBePushed: true))
                    .sidebarRow(.tag(name: "v2.4.0"))
            } header: {
                SidebarSectionHeader("Tags")
            }
            Section {
                StashRow(content: StashRowContent(branch: "main", fileCount: 3, isCurrentBranch: false))
                    .sidebarRow(.stash(branch: "main"))
            } header: {
                SidebarSectionHeader("Stashes")
            }
        }
        .sidebarListStyle()
        .environment(\.sidebarSelection, selection)
        .overlay(alignment: .trailing) {
            Hairline(.vertical)
        }
        .frame(width: Metrics.Column.sidebar.ideal, height: 560)
    }

    @Test("the sidebar: places, branches in their colors, pull requests, tags, and stashes")
    func sidebar() {
        assertSnapshot(sidebar(selection: .changes), named: "sidebar", area: area)
    }

    @Test("the toolbar: the location control, the search field, the last fetch, the sync button, and the overflow menu")
    func toolbar() {
        let push = SyncButtonState(
            kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 0), tagsToPush: 0),
            lastFetched: UIFixtures.minutesAgo(2)
        )
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: UIFixtures.minutesAgo(2))
        let location = LocationControlState(
            repository: .repository(name: "meridian", path: "/Users/joe/Developer/meridian"),
            branch: .branch(name: "feature/hourly-forecast")
        )
        let view = VStack(spacing: 0) {
            ForEach([push, fetch], id: \.title) { sync in
                HStack(spacing: 10) {
                    LocationControlView(location)
                    Spacer(minLength: Metrics.insetMedium)
                    CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                        .controlSize(.large)
                        .frame(width: Metrics.Toolbar.searchWidth)
                    LastFetchedLabel(sync)
                    SyncButtonView(sync)
                        .controlSize(.large)
                    Button {} label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.icon)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .frame(height: Metrics.Toolbar.height - 1)
                Hairline()
            }
        }
        .frame(width: 1_000)
        .background(Color(espalier: Palette.background))
        assertSnapshot(view, named: "toolbar", area: area)
    }
}

// Settings ▸ Home: opening to Home; the watched folders, each with its name
// and where it is, Show in Finder and Stop Watching, and Watch Folder…,
// with what watching does, that a scan runs, and what the last watch from
// here added; then how the shelf is arranged, the kinds of activity that
// move work up, and what counts as needing the user.

import EspalierCore
import EspalierSupport
import SwiftUI

/// Settings ▸ Home.
public struct HomePane: View {
    private let model: AppModel?
    @Environment(WindowContext.self) private var context: WindowContext?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            HomeForm(
                preferences: model.preferences,
                isScanning: model.isScanningFolders,
                actions: context.map { HomePaneActions(context: $0) }
            )
        } else {
            SettingsPanePlaceholder(tab: .home)
        }
    }
}

/// The Home pane's values and copy.
enum HomeSettings {
    /// How the shelf is arranged, in order.
    static let arrangements = [
        CapsuleSegment("Recent Activity", value: RepositoryArrangement.recentActivity),
        CapsuleSegment("Needs You", value: RepositoryArrangement.needsYou),
    ]

    /// The kinds of activity that move work up, in order.
    static let activityKinds: [(title: String, value: WorktreeActivityKind)] = [
        ("Files change", .files),
        ("A commit or a branch switch", .head),
        ("New commits arrive from the server", .server),
        ("News about its pull request", .pullRequest),
    ]

    /// The reasons that put work in Needs You, in order.
    static let needsYouReasons: [(title: String, value: NeedsYouReason)] = [
        ("Uncommitted changes", .uncommittedChanges),
        ("Commits to push", .commitsToPush),
        ("A rebase or merge that stopped", .stoppedOperation),
        ("Checks failing or a review waiting on its pull request", .pullRequestAttention),
        ("A merged branch to clean up", .mergedReadyToCleanUp),
        ("Commits to pull", .commitsToPull),
        ("A pushed branch with no pull request", .branchWithoutPullRequest),
    ]
}

/// What the Home pane's buttons do.
@MainActor
struct HomePaneActions {
    let context: WindowContext

    /// Asks for folders to watch, watches them, and says what happened;
    /// nil when the user cancels.
    func watch() async -> WatchFolderReport? {
        guard let paths = await WatchFolders.chooseFolders(in: context) else {
            return nil
        }
        let app = context.app
        let results = await app.watchFolders(paths)
        return WatchFolderReport(results, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat)
    }

    func showInFinder(_ folder: String) async {
        await RepositoryActions.showInFinder(folder, in: context)
    }

    func stopWatching(_ folder: String) {
        context.app.removeWatchedFolder(folder)
    }
}

/// The Home pane: Open to Home, the watched folders, and how work is
/// arranged.
struct HomeForm: View {
    @Bindable var preferences: Preferences
    /// A scan of the watched folders runs.
    let isScanning: Bool
    let actions: HomePaneActions?
    /// What the last Watch Folder… from this pane did, until a folder is
    /// watched or stopped again.
    @State var report: WatchFolderReport?

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsToggleRow(
                    "Open to Home",
                    description: "Windows open to Home, an overview of the work in your repositories, and the toolbar has a button for it.",
                    isOn: $preferences.showsHome
                )
            }

            SettingsSection("Watched folders") {
                ForEach(preferences.watchedFolders.map(ExactString.init), id: \.self) { exact in
                    let folder = exact.value
                    WatchedFolderRow(
                        folder: folder,
                        showInFinder: {
                            let actions = actions
                            Task { await actions?.showInFinder(folder) }
                        },
                        stopWatching: {
                            report = nil
                            actions?.stopWatching(folder)
                        }
                    )
                    .settingsTransition()
                }
                if isScanning {
                    SettingsMessageRow {
                        HStack(spacing: Metrics.insetSmall) {
                            ArcProgress(.mini)
                            SettingsNote("Looking for repositories…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .settingsTransition()
                } else if let report {
                    SettingsMessageRow {
                        Label(report.message, systemImage: report.tone == .success ? "checkmark.circle.fill" : "info.circle")
                            .font(Typography.secondary)
                            .foregroundStyle(.text2)
                    }
                    .settingsTransition()
                }
                SettingsMessageRow {
                    SettingsNote(preferences.watchedFolders.isEmpty
                        ? "You're not watching any folders. Espalier adds the repositories it finds in a folder you watch, and keeps looking as new ones appear."
                        : "Espalier adds the repositories it finds in these folders, and keeps looking as new ones appear. A repository you remove from the list stays removed until you add it again.")
                } trailing: {
                    Button("Watch Folder…") {
                        let actions = actions
                        Task {
                            guard let report = await actions?.watch() else {
                                return
                            }
                            self.report = report
                        }
                    }
                    .settingsButton()
                }
            }

            SettingsSection("Arranging work") {
                SettingsRow("Arrange the shelf by", labelsControl: true) {
                    CapsuleSegmentedControl("Arrange the shelf by", selection: $preferences.repositoryArrangement, segments: HomeSettings.arrangements)
                        .fixedSize()
                }
                SettingsRow("Recent Activity moves work up when") {
                    EmptyView()
                } footer: {
                    SettingsChecklist(choices: HomeSettings.activityKinds, selection: $preferences.recentActivityKinds)
                }
                SettingsRow("Needs You includes") {
                    EmptyView()
                } footer: {
                    SettingsChecklist(choices: HomeSettings.needsYouReasons, selection: $preferences.needsYouReasons)
                }
            }
        }
        // A folder watched or stopped, a scan, and what watching said: the
        // rows they bring or take away fade over 0.22 s, the rows below
        // making room or closing the gap.
        .motion(Motion.arrive, value: preferences.watchedFolders)
        .motion(Motion.arrive, value: isScanning)
        .motion(Motion.arrive, value: report)
    }
}

/// A watched folder: its name and where it is, and its actions, Show in
/// Finder and Stop Watching, in its "⋯" menu and its context menu.
struct WatchedFolderRow: View {
    let folder: String
    let showInFinder: () -> Void
    let stopWatching: () -> Void

    var body: some View {
        let title = WatchedFolderNames.title(of: folder)
        HStack(spacing: Metrics.SettingsWindow.rowSpacing) {
            SettingsRowText(title: title, description: RepositoryRowContent.abbreviatedPath(folder))
                .accessibilityElement(children: .combine)
            RowActionsMenu("Actions for \(title)") { [showInFinder, stopWatching] in
                MenuAction("Show in Finder", action: showInFinder)
                MenuAction("Stop Watching", action: stopWatching)
            }
        }
        .padding(.vertical, Metrics.SettingsWindow.rowVerticalPadding)
        .frame(minHeight: Metrics.SettingsWindow.rowHeight)
        .contentShape(Rectangle())
        .contextMenuCard { [showInFinder, stopWatching] in
            MenuAction("Show in Finder", action: showInFinder)
            MenuAction("Stop Watching", action: stopWatching)
        }
    }
}

/// A row's checkboxes, one for each choice, on when the choice is in
/// `selection`.
struct SettingsChecklist<Value: Hashable>: View {
    let choices: [(title: String, value: Value)]
    @Binding var selection: Set<Value>

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            ForEach(choices, id: \.value) { choice in
                Toggle(choice.title, isOn: Binding {
                    selection.contains(choice.value)
                } set: { isOn in
                    if isOn {
                        selection.insert(choice.value)
                    } else {
                        selection.remove(choice.value)
                    }
                })
                .toggleStyle(.checkboxMark)
                .font(Typography.row)
            }
        }
        .padding(.top, Metrics.grid)
        .padding(.vertical, Metrics.FocusRing.outset)
    }
}

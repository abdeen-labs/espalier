// The main window on a believable project, for the website: History's graph
// with a commit's Swift diff, and Changes with a commit being written. The
// project is Harbor, a tide-times app, made by four people over two weeks:
// a merged widget branch, an open charts branch, a tag, two commits not yet
// pushed, and three files changed but not committed.
// `--look` draws them in each theme.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Showcase", .captures, .offline, .serialized, .hangGuard(minutes: 5)) @MainActor
struct ShowcaseCaptures {
    private let area = "Showcase"

    @Test("History: Harbor's graph, and the offline cache commit's diff")
    func history() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await MainWindowFixture.make(try await Harbor.make())
            await fixture.show(.history)
            fixture.context.state.columnVisibility = .all
            await fixture.selectCommittedFile("Harbor/TideStore.swift")
            await captureWindow(fixture, named: "history", showsDiff: true)
        }
    }

    @Test("Changes: three files changed, TideView.swift's diff, and a summary written")
    func changes() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await MainWindowFixture.make(try await Harbor.make())
            fixture.context.state.columnVisibility = .all
            fixture.context.state.select(.changes, in: fixture.repository.id)
            await fixture.settle()
            if let file = fixture.repository.changes.workingDirectory.files.first(where: { $0.path == "Harbor/TideView.swift" }) {
                fixture.repository.changes.select(fileIDs: [file.id])
            }
            var draft = CommitDraft()
            draft.summary = "Show the tide height next to each time"
            draft.description = "Heights use the units of the user's locale."
            fixture.repository.commit.draft = draft
            await fixture.settle()
            await captureWindow(fixture, named: "changes", showsDiff: true)
        }
    }

    /// A Mac window's shape, with room for the diff's lines.
    private static let size = CGSize(width: 1_440, height: 900)

    /// Draws the fixture's window in each appearance, its diff in color and
    /// unwrapped, once the diff (when `showsDiff`) has colored rows and the
    /// window has stopped changing.
    private func captureWindow(_ fixture: MainWindowFixture, named name: String, showsDiff: Bool) async {
        FlatWindowChrome.install()
        // A fixed name in the location control, not the folder's.
        fixture.app.setAlias("harbor", for: fixture.repository.id)
        fixture.app.preferences.wrapDiffLines = false
        await fixture.settle()
        for appearance in CaptureAppearance.allCases {
            var stage: MainWindowStage? = autoreleasepool {
                MainWindowStage(fixture.context, appearance: appearance, size: Self.size, highlighter: TreeSitterHighlighter())
            }
            // The diff shows its rows first and its colors once the
            // highlighter is done.
            await stage?.settle {
                !showsDiff || stage?.views(DiffTableView.self).contains {
                    $0.numberOfRows > 0 && $0.controller?.shownContent?.tokens.isEmpty == false
                } == true
            }
            let image = stage?.image
            autoreleasepool {
                stage?.close()
                stage = nil
            }
            if let image {
                capture(named: name, area: area, appearances: [appearance]) { _ in image }
            }
            // The window's toolbar leaves the family once it's released.
            await Task.yield()
        }
        await fixture.settle()
    }
}

private extension MainWindowFixture {
    /// Selects the changed file at `path` in the selected commit, once the
    /// commit's files have loaded.
    func selectCommittedFile(_ path: String) async {
        await settle()
        if case .loaded(let changeset) = repository.history.selection.changeset,
           let file = changeset.files.first(where: { $0.path == path }) {
            repository.history.selectFile(file)
        }
        await settle()
    }
}

/// Harbor's repository: who wrote what, and when.
private enum Harbor {
    struct Person {
        let name: String
        let email: String
    }

    static let maya = Person(name: "Maya Lindqvist", email: "maya@harbor.example")
    static let tomas = Person(name: "Tom\u{E1}s Okafor", email: "tomas@harbor.example")
    static let priya = Person(name: "Priya Raman", email: "priya@harbor.example")
    static let leo = Person(name: "Leo Hartmann", email: "leo@harbor.example")

    /// `main` from Initial commit to Cache tides for offline use (HEAD), with
    /// `feature/widget` merged and `feature/charts` open; `origin` has `main`
    /// up to Update README for the widget, so the last two commits and the
    /// v1.3 tag aren't pushed. Priya is the one committing: TideView.swift
    /// and the widget are changed and HeightFormatter.swift is new, not
    /// committed.
    static func make() async throws -> Repository {
        let local = try setupEmptyRepository("main")
        let origin = try createTempDirectory()
        _ = try await runGit(["init", "-q", "--bare", origin], local)
        _ = try await runGit(["remote", "add", "origin", origin], local)
        _ = try await runGit(["config", "user.name", priya.name], local)
        _ = try await runGit(["config", "user.email", priya.email], local)

        // Hours before now, so the history reads as recent work.
        let now = Int(Date().timeIntervalSince1970)
        func commit(_ person: Person, hoursAgo: Double, _ message: String, files: [String: String]) async throws {
            for (path, contents) in files {
                try write(contents, to: path, in: local)
            }
            _ = try await runGit(["add", "--all"], local)
            try await dated(person, hoursAgo: hoursAgo, now: now) {
                _ = try await runGit(["commit", "-q", "-m", message], local)
            }
        }

        try await commit(maya, hoursAgo: 330, "Initial commit", files: ["README.md": readme, "Harbor/Station.swift": station])
        try await commit(maya, hoursAgo: 306, "Add tide station client", files: ["Harbor/StationClient.swift": stationClient])
        try await commit(priya, hoursAgo: 285, "Parse tides in the station's time zone", files: ["Harbor/Tide.swift": tide])
        try await commit(tomas, hoursAgo: 260, "Show the next high and low tide", files: ["Harbor/TideView.swift": tideView])
        try await commit(maya, hoursAgo: 236, "Load tides for followed stations", files: ["Harbor/TideStore.swift": tideStore])
        _ = try await runGit(["tag", "v1.2"], local)

        _ = try await runGit(["checkout", "-q", "-b", "feature/widget"], local)
        try await commit(leo, hoursAgo: 190, "Add a widget for the next tide", files: ["Widget/NextTideWidget.swift": widget])
        try await commit(leo, hoursAgo: 166, "Refresh the widget at each turn of the tide", files: ["Widget/NextTideWidget.swift": widgetRefreshing])
        _ = try await runGit(["checkout", "-q", "main"], local)
        try await commit(tomas, hoursAgo: 150, "Fix crash when a station has no tides", files: ["Harbor/TideView.swift": tideViewEmpty])
        try await dated(maya, hoursAgo: 120, now: now) {
            _ = try await runGit(["merge", "-q", "--no-ff", "-m", "Merge branch 'feature/widget'", "feature/widget"], local)
        }

        _ = try await runGit(["checkout", "-q", "-b", "feature/charts"], local)
        try await commit(tomas, hoursAgo: 72, "Draw the tide curve", files: ["Harbor/TideChart.swift": tideChart])
        try await commit(tomas, hoursAgo: 49, "Label high and low on the curve", files: ["Harbor/TideChart.swift": tideChartLabeled])
        _ = try await runGit(["checkout", "-q", "main"], local)

        try await commit(leo, hoursAgo: 30, "Update README for the widget", files: ["README.md": readmeWidget])
        _ = try await runGit(["push", "-q", "-u", "origin", "main", "v1.2"], local)
        try await commit(maya, hoursAgo: 7, "Bump version to 1.3", files: ["Harbor.xcconfig": "MARKETING_VERSION = 1.3\nCURRENT_PROJECT_VERSION = 14\n"])
        _ = try await runGit(["tag", "v1.3"], local)
        try await commit(priya, hoursAgo: 2, "Cache tides for offline use", files: [
            "Harbor/TideStore.swift": tideStoreCached,
            "Harbor/TideCache.swift": tideCache,
        ])

        try write(tideViewHeights, to: "Harbor/TideView.swift", in: local)
        try write(heightFormatter, to: "Harbor/HeightFormatter.swift", in: local)
        try write(widgetHeights, to: "Widget/NextTideWidget.swift", in: local)
        return local
    }

    /// Runs `body` with `person` as author and committer, `hoursAgo` hours
    /// before `now`.
    private static func dated(_ person: Person, hoursAgo: Double, now: Int, _ body: () async throws -> Void) async throws {
        let date = "\(now - Int(hoursAgo * 3_600)) +0000"
        try await withGitEnvironment([
            "GIT_AUTHOR_NAME": person.name, "GIT_AUTHOR_EMAIL": person.email, "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_NAME": person.name, "GIT_COMMITTER_EMAIL": person.email, "GIT_COMMITTER_DATE": date,
        ]) {
            try await body()
        }
    }

    private static func write(_ contents: String, to path: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(exactFilePath: fullPath))
    }

    // MARK: Files

    static let readme = """
        # Harbor

        Tide times for the stations you follow.

        ## Building

        Open `Harbor.xcodeproj` and run the Harbor scheme.

        """

    static let readmeWidget = """
        # Harbor

        Tide times for the stations you follow, in the app and on your Home Screen.

        ## Building

        Open `Harbor.xcodeproj` and run the Harbor scheme. The widget is in the
        HarborWidget target; it shares `TideStore` with the app through the
        Harbor app group.

        """

    static let station = """
        import Foundation

        /// A tide station: where tides are predicted.
        struct Station: Identifiable, Codable, Hashable {
            let id: String
            let name: String
            let timeZone: TimeZone
        }

        """

    static let stationClient = """
        import Foundation

        /// Fetches a station's predicted tides.
        struct StationClient {
            var session: URLSession = .shared
            var baseURL = URL(string: "https://tides.harbor.example/v2")!

            func tides(at station: Station, days: Int = 2) async throws -> [Tide] {
                let url = baseURL.appending(path: "stations/\\(station.id)/tides")
                    .appending(queryItems: [URLQueryItem(name: "days", value: "\\(days)")])
                let (data, _) = try await session.data(from: url)
                return try JSONDecoder.tides.decode([Tide].self, from: data)
            }
        }

        """

    static let tide = """
        import Foundation

        /// A predicted high or low tide.
        struct Tide: Codable, Hashable {
            enum Kind: String, Codable {
                case high, low
            }

            let kind: Kind
            let date: Date
            /// Height above chart datum, in meters.
            let height: Double
        }

        extension JSONDecoder {
            /// Decodes the station API's ISO 8601 dates.
            static let tides: JSONDecoder = {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return decoder
            }()
        }

        """

    static let tideView = """
        import SwiftUI

        /// The next high and low tide at a station.
        struct TideView: View {
            let station: Station
            let tides: [Tide]

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text(station.name)
                        .font(.title2.bold())
                    ForEach(upcoming, id: \\.date) { tide in
                        HStack {
                            Label(tide.kind == .high ? "High" : "Low",
                                  systemImage: tide.kind == .high ? "arrow.up" : "arrow.down")
                            Spacer()
                            Text(tide.date, style: .time)
                                .monospacedDigit()
                        }
                    }
                }
                .padding()
            }

            private var upcoming: [Tide] {
                Array(tides.filter { $0.date > .now }.prefix(2))
            }
        }

        """

    static let tideViewEmpty = """
        import SwiftUI

        /// The next high and low tide at a station.
        struct TideView: View {
            let station: Station
            let tides: [Tide]

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text(station.name)
                        .font(.title2.bold())
                    if upcoming.isEmpty {
                        Text("No tides in the next two days")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(upcoming, id: \\.date) { tide in
                        HStack {
                            Label(tide.kind == .high ? "High" : "Low",
                                  systemImage: tide.kind == .high ? "arrow.up" : "arrow.down")
                            Spacer()
                            Text(tide.date, style: .time)
                                .monospacedDigit()
                        }
                    }
                }
                .padding()
            }

            private var upcoming: [Tide] {
                Array(tides.filter { $0.date > .now }.prefix(2))
            }
        }

        """

    static let tideViewHeights = """
        import SwiftUI

        /// The next high and low tide at a station, with their heights.
        struct TideView: View {
            let station: Station
            let tides: [Tide]
            private let heights = HeightFormatter()

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text(station.name)
                        .font(.title2.bold())
                    if upcoming.isEmpty {
                        Text("No tides in the next two days")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(upcoming, id: \\.date) { tide in
                        HStack {
                            Label(tide.kind == .high ? "High" : "Low",
                                  systemImage: tide.kind == .high ? "arrow.up" : "arrow.down")
                            Spacer()
                            Text(heights.string(for: tide.height))
                                .foregroundStyle(.secondary)
                            Text(tide.date, style: .time)
                                .monospacedDigit()
                        }
                    }
                }
                .padding()
            }

            private var upcoming: [Tide] {
                Array(tides.filter { $0.date > .now }.prefix(2))
            }
        }

        """

    static let heightFormatter = """
        import Foundation

        /// Formats a tide height in the user's units: meters, or feet
        /// where the locale measures in feet.
        struct HeightFormatter {
            var locale: Locale = .autoupdatingCurrent

            func string(for meters: Double) -> String {
                Measurement(value: meters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road)
                        .locale(locale))
            }
        }

        """

    static let tideStore = """
        import Foundation

        /// Loads the tides for the stations you follow.
        @MainActor
        final class TideStore: ObservableObject {
            @Published private(set) var tides: [Station.ID: [Tide]] = [:]

            private let client: StationClient

            init(client: StationClient = .init()) {
                self.client = client
            }

            func refresh(_ station: Station) async throws {
                let fetched = try await client.tides(at: station)
                tides[station.id] = fetched
            }
        }

        """

    static let tideStoreCached = """
        import Foundation

        /// Loads the tides for the stations you follow, and keeps
        /// the last ones on disk for when you're offline.
        @MainActor
        final class TideStore: ObservableObject {
            @Published private(set) var tides: [Station.ID: [Tide]] = [:]

            private let client: StationClient
            private let cache: TideCache

            init(client: StationClient = .init(), cache: TideCache = .shared) {
                self.client = client
                self.cache = cache
            }

            func refresh(_ station: Station) async throws {
                do {
                    let fetched = try await client.tides(at: station)
                    tides[station.id] = fetched
                    try cache.store(fetched, for: station.id)
                } catch URLError.notConnectedToInternet {
                    tides[station.id] = try cache.tides(for: station.id)
                }
            }
        }

        """

    static let tideCache = """
        import Foundation

        /// The last tides fetched for each station, on disk.
        struct TideCache {
            static let shared = TideCache(directory: .cachesDirectory.appending(path: "Tides"))

            let directory: URL

            func store(_ tides: [Tide], for station: Station.ID) throws {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(tides).write(to: file(for: station), options: .atomic)
            }

            func tides(for station: Station.ID) throws -> [Tide] {
                try JSONDecoder.tides.decode([Tide].self, from: Data(contentsOf: file(for: station)))
            }

            private func file(for station: Station.ID) -> URL {
                directory.appending(path: "\\(station).json")
            }
        }

        """

    static let widget = """
        import SwiftUI
        import WidgetKit

        /// The next tide at the user's first station.
        struct NextTideWidget: Widget {
            var body: some WidgetConfiguration {
                StaticConfiguration(kind: "NextTide", provider: TideTimeline()) { entry in
                    NextTideView(entry: entry)
                }
                .configurationDisplayName("Next Tide")
                .description("The next high or low tide at your station.")
                .supportedFamilies([.systemSmall, .accessoryRectangular])
            }
        }

        """

    static let widgetRefreshing = """
        import SwiftUI
        import WidgetKit

        /// The next tide at the user's first station, refreshed as each
        /// tide turns.
        struct NextTideWidget: Widget {
            var body: some WidgetConfiguration {
                StaticConfiguration(kind: "NextTide", provider: TideTimeline(policy: .atEachTurn)) { entry in
                    NextTideView(entry: entry)
                }
                .configurationDisplayName("Next Tide")
                .description("The next high or low tide at your station.")
                .supportedFamilies([.systemSmall, .accessoryRectangular])
            }
        }

        """

    static let widgetHeights = """
        import SwiftUI
        import WidgetKit

        /// The next tide at the user's first station, with its height,
        /// refreshed as each tide turns.
        struct NextTideWidget: Widget {
            var body: some WidgetConfiguration {
                StaticConfiguration(kind: "NextTide", provider: TideTimeline(policy: .atEachTurn)) { entry in
                    NextTideView(entry: entry, showsHeight: true)
                }
                .configurationDisplayName("Next Tide")
                .description("The next high or low tide at your station, and how high.")
                .supportedFamilies([.systemSmall, .accessoryRectangular])
            }
        }

        """

    static let tideChart = """
        import Charts
        import SwiftUI

        /// The tide's height over the next day.
        struct TideChart: View {
            let tides: [Tide]

            var body: some View {
                Chart(tides, id: \\.date) { tide in
                    LineMark(x: .value("Time", tide.date), y: .value("Height", tide.height))
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel("m")
            }
        }

        """

    static let tideChartLabeled = """
        import Charts
        import SwiftUI

        /// The tide's height over the next day, with each high and low marked.
        struct TideChart: View {
            let tides: [Tide]

            var body: some View {
                Chart(tides, id: \\.date) { tide in
                    LineMark(x: .value("Time", tide.date), y: .value("Height", tide.height))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Time", tide.date), y: .value("Height", tide.height))
                        .annotation(position: tide.kind == .high ? .top : .bottom) {
                            Text(tide.kind == .high ? "High" : "Low")
                                .font(.caption2)
                        }
                }
                .chartYAxisLabel("m")
            }
        }

        """
}

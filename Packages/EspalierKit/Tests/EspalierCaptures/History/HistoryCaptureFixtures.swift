// The repositories History's captures show, each selected in an app with a
// window: History's places (main with a merged feature, a branch off it,
// and a tag), the graph table's rows (a merge, unpushed commits, branches,
// a remote branch, and tags on one commit), a history taller than its
// list, and the simple list's feature branch. Commits are dated back from
// now, so their times read as recent.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import TestSupport
@testable import EspalierUI

/// A repository selected in an app, with a window.
@MainActor
struct HistoryCaptureFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    let local: Repository
    /// The commits by summary.
    let shas: [String: String]

    var history: HistoryModel {
        repository.history
    }

    /// Waits for the repository and its history to settle.
    func settle() async {
        await app.idle()
        await history.idle()
    }

    /// Shows `place`, as its screen does when it appears, and waits for it.
    func show(_ place: SidebarPlace) async {
        context.state.select(place, in: repository.id)
        history.activate()
        await settle()
        await HistoryPlaces.enter(place, repository: repository, context: context)
        await settle()
    }
}

/// Makes commits dated back from now.
private struct DatedCommits {
    let repository: Repository
    var shas: [String: String] = [:]

    /// Runs git as `author` (Joe Bloggs by default) at `minutesAgo`;
    /// returns HEAD's SHA.
    func run(_ args: [String], by author: String? = nil, minutesAgo: Int) async throws -> String {
        let date = "\(Int(Date.now.timeIntervalSince1970) - minutesAgo * 60) +0000"
        var environment = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        if let author {
            environment["GIT_AUTHOR_NAME"] = author
            environment["GIT_AUTHOR_EMAIL"] = author.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
        }
        return try await withGitEnvironment(environment) {
            try await runGit(args, repository)
            return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
    }

    /// Writes and adds `files` (the summary and an index in each), then
    /// commits them as `summary`.
    mutating func commit(_ summary: String, files: [String], by author: String? = nil, minutesAgo: Int) async throws {
        for (index, path) in files.enumerated() {
            let fullPath = POSIXPath.join(repository.path, path)
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
            try Data("\(summary) \(index)\n".utf8).write(to: URL(exactFilePath: fullPath))
            try await runGit(["add", "--", path], repository)
        }
        shas[summary] = try await run(["commit", "-q", "-m", summary], by: author, minutesAgo: minutesAgo)
    }

    /// Merges `branch` with a merge commit.
    mutating func merge(_ branch: String, _ message: String, by author: String? = nil, minutesAgo: Int) async throws {
        shas[message] = try await run(["merge", "-q", "--no-ff", "-m", message, branch], by: author, minutesAgo: minutesAgo)
    }
}

/// Selects `local` in a new app with a window whose avatars are monograms.
@MainActor
private func selectInApp(
    _ local: Repository,
    shas: [String: String],
    historyStyle: HistoryStyle? = .graph
) async throws -> HistoryCaptureFixture {
    let harness = try AppHarness(historyStyle: historyStyle)
    let app = await harness.loadedApp()
    app.preferences.hasShownWelcomeFlow = true
    let repository = try await harness.addAndSelect(local, to: app)
    let context = WindowContext(app: app)
    context.avatarLoader = MonogramAvatarLoader()
    return HistoryCaptureFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: shas)
}

/// `main`: Initial commit, Add loader (tagged v1.0), Update docs, a merge
/// of `feature/login` (Add sign-in sheet, Wire device flow, from Add
/// loader), Bump version (HEAD); `fix/crash` from Update docs with Fix
/// crash on empty repository. Commits are half an hour apart from a day
/// ago; unless `dirty` is false, README.md is changed but not committed.
@MainActor
func makeHistoryPlaceFixture(dirty: Bool = true) async throws -> HistoryCaptureFixture {
    let local = try setupEmptyRepository("main")
    var commits = DatedCommits(repository: local)
    var minutesAgo = 24 * 60
    func next() -> Int {
        minutesAgo -= 30
        return minutesAgo
    }
    try await commits.commit("Initial commit", files: ["README.md"], minutesAgo: next())
    try await commits.commit("Add loader", files: ["Sources/Loader.swift"], minutesAgo: next())
    try await runGit(["tag", "v1.0"], local)
    try await runGit(["checkout", "-q", "-b", "feature/login"], local)
    try await commits.commit("Add sign-in sheet", files: ["Sources/SignIn.swift"], minutesAgo: next())
    try await commits.commit("Wire device flow", files: ["Sources/DeviceFlow.swift"], minutesAgo: next())
    try await runGit(["checkout", "-q", "main"], local)
    try await commits.commit("Update docs", files: ["docs/Guide.md"], minutesAgo: next())
    try await runGit(["checkout", "-q", "-b", "fix/crash"], local)
    try await commits.commit("Fix crash on empty repository", files: ["Sources/Empty.swift"], minutesAgo: next())
    try await runGit(["checkout", "-q", "main"], local)
    try await commits.merge("feature/login", "Merge branch 'feature/login'", minutesAgo: next())
    try await commits.commit("Bump version", files: ["VERSION"], minutesAgo: next())
    if dirty {
        try Data("Changed\n".utf8).write(to: URL(exactFilePath: POSIXPath.join(local.path, "README.md")))
    }
    return try await selectInApp(local, shas: commits.shas)
}

/// `main`: Initial commit, Add forecast model, Release 2.3 (tagged v1.0,
/// v1.1, and v1.2, and `origin/release`'s tip), Update docs (`origin/main`,
/// its upstream), and a merge of `feature/login` (Add sign-in sheet, Sign
/// in with the device flow, from Release 2.3), checked out: the merge and
/// the feature's commits aren't pushed. Unless `dirty` is false, three
/// files are changed but not committed.
@MainActor
func makeHistoryTableFixture(dirty: Bool = true) async throws -> HistoryCaptureFixture {
    let local = try setupEmptyRepository("main")
    var commits = DatedCommits(repository: local)
    try await commits.commit("Initial commit", files: ["README.md"], by: "Leo Park", minutesAgo: 6 * 24 * 60)
    try await commits.commit("Add forecast model", files: ["Sources/Forecast.swift"], by: "Priya Nair", minutesAgo: 3 * 24 * 60)
    try await commits.commit("Release 2.3", files: ["VERSION"], by: "Sam Ortiz", minutesAgo: 2 * 24 * 60)
    for tag in ["v1.0", "v1.1", "v1.2"] {
        try await runGit(["tag", tag], local)
    }
    let remote = try await makeBareRemote(from: local)
    try await runGit(["remote", "add", "origin", remote.path], local)
    try await runGit(["push", "-q", "origin", "main:release"], local)
    try await runGit(["checkout", "-q", "-b", "feature/login"], local)
    try await commits.commit("Add sign-in sheet", files: ["Sources/SignIn.swift"], by: "Maya Chen", minutesAgo: 26 * 60)
    try await commits.commit("Sign in with the device flow", files: ["Sources/DeviceFlow.swift"], by: "Maya Chen", minutesAgo: 20 * 60)
    try await runGit(["checkout", "-q", "main"], local)
    try await commits.commit("Update docs", files: ["docs/Guide.md"], by: "Jonas Weber", minutesAgo: 5 * 60)
    try await runGit(["push", "-q", "-u", "origin", "main"], local)
    try await commits.merge("feature/login", "Merge branch 'feature/login'", by: "Maya Chen", minutesAgo: 45)
    if dirty {
        for path in ["README.md", "Sources/Forecast.swift", "Sources/SignIn.swift"] {
            try Data("Changed\n".utf8).write(to: URL(exactFilePath: POSIXPath.join(local.path, path)))
        }
    }
    return try await selectInApp(local, shas: commits.shas)
}

/// `main`: twenty-seven commits by several authors, two hours apart,
/// tagged v2.0 at the tenth and v2.1 at the twentieth, then a merge of
/// `feature/search` (four commits) and Bump version (HEAD): a history
/// taller than its list.
@MainActor
func makeLongHistoryFixture() async throws -> HistoryCaptureFixture {
    let local = try setupEmptyRepository("main")
    var commits = DatedCommits(repository: local)
    let authors = ["Leo Park", "Priya Nair", "Sam Ortiz", "Maya Chen", "Jonas Weber"]
    let summaries = [
        "Initial commit", "Add forecast model", "Fetch current conditions", "Show the temperature in the menu bar",
        "Add a settings window", "Remember the chosen city", "Localize the units", "Draw the radar overlay",
        "Cache forecasts for an hour", "Release 2.0", "Fix the radar's colors in dark mode", "Add severe weather alerts",
        "Show alerts as notifications", "Tune the alert sounds", "Add the hourly chart", "Animate the hourly chart",
        "Fix a crash when offline", "Update the app icon", "Add a widget", "Release 2.1",
        "Refresh the widget's timeline", "Use the new widget sizes", "Speed up launching", "Fix the chart's labels",
        "Add air quality", "Show the pollen count", "Update docs",
    ]
    var minutesAgo = 3 * 24 * 60
    for (index, summary) in summaries.enumerated() {
        minutesAgo -= 120
        let name = String(summary.lowercased().map { $0.isLetter ? $0 : "-" })
        try await commits.commit(summary, files: ["\(name).txt"], by: authors[index % authors.count], minutesAgo: minutesAgo)
        if summary.hasPrefix("Release ") {
            try await runGit(["tag", "v" + summary.dropFirst("Release ".count)], local)
        }
    }
    try await runGit(["checkout", "-q", "-b", "feature/search"], local)
    for summary in ["Add a search field", "Search cities as you type", "Show recent searches", "Clear recent searches"] {
        minutesAgo -= 60
        let name = String(summary.lowercased().map { $0.isLetter ? $0 : "-" })
        try await commits.commit(summary, files: ["\(name).txt"], by: "Maya Chen", minutesAgo: minutesAgo)
    }
    try await runGit(["checkout", "-q", "main"], local)
    try await commits.merge("feature/search", "Merge branch 'feature/search'", by: "Maya Chen", minutesAgo: minutesAgo - 30)
    try await commits.commit("Bump version", files: ["VERSION"], by: "Sam Ortiz", minutesAgo: minutesAgo - 40)
    return try await selectInApp(local, shas: commits.shas)
}

/// `main`: a few commits by several authors, two pull request merges
/// (#205 and #209), a tag, then five commits the feature branch doesn't
/// have; `feature/hourly-forecast`: two pushed commits and two that aren't,
/// checked out. The app shows History in the simple style.
@MainActor
func makeSimpleHistoryFixture() async throws -> HistoryCaptureFixture {
    let seed = try setupEmptyRepository("main")
    var commits = DatedCommits(repository: seed)
    func files(_ summary: String, _ count: Int) -> [String] {
        let name = String(summary.lowercased().map { $0.isLetter ? $0 : "-" })
        return (0..<count).map { "\(name)-\($0).txt" }
    }
    let day = 24 * 60
    try await commits.commit("Tune radar overlay opacity", files: files("Tune radar overlay opacity", 1), by: "Leo Park", minutesAgo: 5 * day)
    try await commits.commit("Localize precipitation strings", files: files("Localize precipitation strings", 1), by: "Priya Nair", minutesAgo: 4 * day + 600)
    try await runGit(["checkout", "-q", "-b", "sam/severe-alerts"], seed)
    try await commits.commit("Add severe weather alerts", files: files("Add severe weather alerts", 1), by: "Sam Ortiz", minutesAgo: 4 * day + 300)
    try await runGit(["checkout", "-q", "main"], seed)
    try await commits.merge("sam/severe-alerts", "Merge pull request #205 from sam/severe-alerts", by: "Sam Ortiz", minutesAgo: 4 * day)
    try await commits.commit("Release 2.3.1", files: files("Release 2.3.1", 1), by: "Sam Ortiz", minutesAgo: 3 * day)
    try await runGit(["tag", "v2.3.1"], seed)
    try await commits.commit("Fix crash when location access is denied", files: files("Fix crash when location access is denied", 1), by: "Leo Park", minutesAgo: 2 * day)
    try await runGit(["checkout", "-q", "-b", "jonas/widget-refresh"], seed)
    try await commits.commit("Refresh the widget's timeline", files: files("Refresh the widget's timeline", 2), by: "Jonas Weber", minutesAgo: day + 600)
    try await commits.commit("Use the new widget sizes", files: files("Use the new widget sizes", 1), by: "Jonas Weber", minutesAgo: day + 500)
    try await runGit(["checkout", "-q", "main"], seed)
    try await commits.merge("jonas/widget-refresh", "Merge pull request #209 from jonas/widget-refresh", by: "Jonas Weber", minutesAgo: day + 400)
    let remote = try await makeBareRemote(from: seed)
    let local = try await cloneRepository(remote)
    var feature = DatedCommits(repository: local, shas: commits.shas)
    try await runGit(["checkout", "-q", "-b", "feature/hourly-forecast"], local)
    try await feature.commit("Add HourlyForecast model", files: files("Add HourlyForecast model", 2), by: "Maya Chen", minutesAgo: day + 300)
    try await feature.commit("Fetch hourly data from the forecast API", files: files("Fetch hourly data from the forecast API", 3), by: "Maya Chen", minutesAgo: 18 * 60)
    try await runGit(["push", "-q", "-u", "origin", "feature/hourly-forecast"], local)
    try await feature.commit("Add HourlyRow view", files: files("Add HourlyRow view", 2), by: "Maya Chen", minutesAgo: 60)
    try await feature.commit("Show hourly forecast for the next 24 hours", files: files("Show hourly forecast for the next 24 hours", 4), by: "Maya Chen", minutesAgo: 12)
    try await runGit(["checkout", "-q", "main"], local)
    for number in 1...5 {
        try await feature.commit("Main moves on \(number)", files: files("Main moves on \(number)", 1), by: "Leo Park", minutesAgo: 600 - number * 60)
    }
    try await runGit(["checkout", "-q", "feature/hourly-forecast"], local)
    let fixture = try await selectInApp(local, shas: feature.shas, historyStyle: nil)
    fixture.context.state.select(.history, in: fixture.repository.id)
    fixture.history.activate()
    await fixture.settle()
    return fixture
}

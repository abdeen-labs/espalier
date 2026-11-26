// What Home says once Fetch All or Push All finishes: a toast when every
// item went through (or the user stopped it), else one alert that names
// each repository or branch that didn't, and why.

import EspalierCore
import GitKit

/// How a batch's outcome is told.
enum HomeBatchReport: Equatable {
    /// Everything went through, or the user stopped it.
    case toast(String, tone: ToastTone)
    /// Some items didn't go through: the alert lists them.
    case alert(title: String, message: String)

    /// What Fetch All did. `name` gives a repository's title.
    static func fetchAll(_ result: FetchAllResult, name: (RepositoryID) -> String, format: NumberFormat) -> HomeBatchReport? {
        let total = result.items.count
        guard total > 0 else {
            return nil
        }
        let fetched = result.items.count { $0.outcome == .fetched }
        let stopped = result.items.count { $0.outcome == .cancelled }
        let failures = result.failures
        guard !failures.isEmpty else {
            if stopped > 0 {
                return .toast("Fetch All stopped after \(counted(fetched, "repository", "repositories", format)).", tone: .notice)
            }
            return .toast("Fetched \(counted(fetched, "repository", "repositories", format)).", tone: .success)
        }
        let lines = failures.map { "\(name($0.repositoryID)): \($0.error.title)" }
        var message = "These weren't fetched:\n\n" + AlertList.lines(lines, numberFormat: format)
        if stopped > 0 {
            message += "\n\nFetch All was stopped before \(counted(stopped, "more was", "more were", format)) fetched."
        }
        return .alert(
            title: fetched == 0 ? "No Repositories Were Fetched" : "Fetched \(formatCount(fetched, format)) of \(formatCount(total, format)) Repositories",
            message: message
        )
    }

    /// What Push All did. `name` gives a worktree's repository's title.
    static func pushAll(_ result: PushAllResult, name: (WorktreeKey) -> String, format: NumberFormat) -> HomeBatchReport? {
        let total = result.items.count
        guard total > 0 else {
            return nil
        }
        var pushed = 0
        var lines: [String] = []
        for item in result.items {
            let why: String
            switch item.outcome {
            case .pushed:
                pushed += 1
                continue
            case .skipped(let reason):
                why = reason.explanation
            case .failed(let error):
                why = error.title
            }
            let what = item.branch.map { "\(name(item.worktree)), \($0)" } ?? name(item.worktree)
            lines.append("\(what): \(why)")
        }
        guard !lines.isEmpty else {
            return .toast("Pushed \(counted(pushed, "branch", "branches", format)).", tone: .success)
        }
        return .alert(
            title: pushed == 0 ? "No Branches Were Pushed" : "Pushed \(formatCount(pushed, format)) of \(formatCount(total, format)) Branches",
            message: "These weren't pushed:\n\n" + AlertList.lines(lines, numberFormat: format)
        )
    }

    /// "1 repository" or "12 repositories".
    private static func counted(_ count: Int, _ singular: String, _ plural: String, _ format: NumberFormat) -> String {
        countedNoun(count, singular, plural, format)
    }
}

extension PushSkipReason {
    /// Why Push All didn't push a branch, after its name.
    var explanation: String {
        switch self {
        case .notPublished: "It isn't published yet."
        case .upToDate: "It has nothing to push."
        case .needsPull: "It needs a pull first."
        case .busy: "Another operation is in progress."
        case .needsUser(let error): error.title
        case .cancelled: "Push All was stopped first."
        }
    }
}

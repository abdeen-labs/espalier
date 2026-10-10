// VoiceOver in the history graph. The drawing is hidden; each row is one
// element whose label is the commit and whose value lists what the drawing
// shows: HEAD, merges, branch tips, tags, unpushed commits, and where long
// lines continue. Rotors find branch tips, tags, merge commits, and
// unpushed commits; the scroll position is announced when scrolling stops.

import AppKit
import EspalierCore
import GitKit

/// VoiceOver's view of the history graph.
enum GraphAccessibility {
    /// The facts a row's drawing shows, in reading order.
    static func value(forRow row: Int, source: any GraphTableSource, presentation: GraphPresentation) -> String {
        guard let commit = source.commit(atRow: row) else {
            let summary = presentation.workingCopy
            return summary.isDirty ? "Uncommitted changes, \(summary.detail ?? "")." : "No uncommitted changes."
        }
        var facts: [String] = []
        if commit.sha == presentation.headSHA {
            facts.append("HEAD.")
        }
        if commit.parentSHAs.count > 1 {
            facts.append("Merge commit with \(commit.parentSHAs.count) parents.")
        }
        let refs = source.refs(at: commit.sha)
        let branches = refs.filter { $0.kind != .tag }.map(\.name)
        if !branches.isEmpty {
            facts.append("Branch tip: \(branches.joined(separator: ", ")).")
        }
        for tag in refs where tag.kind == .tag {
            facts.append("Tag \(tag.name).")
        }
        if presentation.hasRemote, source.isLocalCommit(commit.sha) {
            facts.append("Not pushed.")
        }
        let graphRow = source.graph[row]
        for edge in graphRow.edges {
            switch edge.kind {
            case .outgoingStub:
                let which = edge.parentIndex == 0 || edge.parentIndex == nil ? "First parent" : "Parent \((edge.parentIndex ?? 0) + 1)"
                if let parentRow = edge.parentRow {
                    facts.append("\(which) is \(commits(parentRow - row)) below.")
                } else {
                    facts.append("\(which) isn't loaded.")
                }
            case .incomingStub:
                if let childRow = edge.childRow {
                    facts.append("Continues from \(commits(row - childRow)) above.")
                }
            default:
                break
            }
        }
        return facts.joined(separator: " ")
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(formatCount(count)) commits"
    }

    /// "Commits 120 to 160 of 1,204 loaded", announced when scrolling stops
    /// while VoiceOver runs.
    static func scrollStatus(_ controller: GraphTableController) -> String? {
        let visible = controller.tableView.rows(in: controller.tableView.visibleRect)
        guard visible.length > 0, controller.shownRowCount > 0 else {
            return nil
        }
        let first = visible.location + 1
        let last = min(visible.location + visible.length, controller.shownRowCount)
        return "Commits \(formatCount(first)) to \(formatCount(last)) of \(formatCount(controller.shownRowCount)) loaded"
    }

    static func announceScrollStatus(_ controller: GraphTableController) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let status = scrollStatus(controller) else {
            return
        }
        NSAccessibility.post(element: controller.tableView, notification: .announcementRequested, userInfo: [
            .announcement: status,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// The graph's rotors: Branch Tips, Tags, Merge Commits, Unpushed
    /// Commits.
    static func rotors(for controller: GraphTableController) -> [NSAccessibilityCustomRotor] {
        RotorKind.allCases.map { kind in
            NSAccessibilityCustomRotor(label: kind.title, itemSearchDelegate: RotorSearch(kind: kind, controller: controller))
        }
    }

    enum RotorKind: CaseIterable {
        case branchTips, tags, mergeCommits, unpushedCommits

        var title: String {
            switch self {
            case .branchTips: "Branch Tips"
            case .tags: "Tags"
            case .mergeCommits: "Merge Commits"
            case .unpushedCommits: "Unpushed Commits"
            }
        }

        func matches(_ commit: Commit, source: any GraphTableSource, presentation: GraphPresentation) -> Bool {
            switch self {
            case .branchTips: source.refs(at: commit.sha).contains { $0.kind != .tag }
            case .tags: source.refs(at: commit.sha).contains { $0.kind == .tag }
            case .mergeCommits: commit.parentSHAs.count > 1
            // Without a remote, nothing is unpushed.
            case .unpushedCommits: presentation.hasRemote && source.isLocalCommit(commit.sha)
            }
        }
    }

    /// Finds a rotor's next or previous row among the loaded commits.
    final class RotorSearch: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
        let kind: RotorKind
        weak var controller: GraphTableController?

        init(kind: RotorKind, controller: GraphTableController) {
            self.kind = kind
            self.controller = controller
        }

        func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
            guard let controller, let source = controller.source else {
                return nil
            }
            let table = controller.tableView
            let count = controller.shownRowCount
            let current = (searchParameters.currentItem?.targetElement as? NSView).map { table.row(for: $0) } ?? -1
            let forward = searchParameters.searchDirection == .next
            var row = current < 0 ? (forward ? -1 : count) : current
            while true {
                row += forward ? 1 : -1
                guard row >= 0, row < count else {
                    return nil
                }
                guard let commit = source.commit(atRow: row), kind.matches(commit, source: source, presentation: controller.presentation) else {
                    continue
                }
                table.scrollRowToVisible(row)
                guard let element = table.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                    return nil
                }
                let result = NSAccessibilityCustomRotor.ItemResult(targetElement: element)
                result.customLabel = RichText.emojified(commit.summary)
                return result
            }
        }
    }
}

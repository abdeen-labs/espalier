// Watch Folder…: the open panel that chooses one or more folders to watch,
// watching them (`AppModel.watchFolders`), and what it says afterward: how
// many repositories were added from which folders, or that none were. Also
// how the watched folders are named: by their name, or by where they are
// when another watched folder has that name.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// Watch Folder…, everywhere it's offered.
@MainActor
enum WatchFolders {
    /// The panel's settings: folders only, several at once, "Watch".
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Espalier adds the repositories in the folders you choose, and new ones as they appear."
        return panel
    }

    /// Shows the panel on `context`'s window and returns the folders chosen;
    /// nil when the user cancels.
    static func chooseFolders(in context: WindowContext) async -> [String]? {
        let panel = makePanel()
        let response: NSApplication.ModalResponse
        if let window = context.modals.topmostWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK else {
            return nil
        }
        return panel.urls.map(AddRepositoryPanel.folderPath)
    }

    /// Watch Folder… in the main window: the panel, then watching what was
    /// chosen, then a toast saying what happened.
    static func present(in context: WindowContext) async {
        guard let paths = await chooseFolders(in: context) else {
            return
        }
        await watch(paths, in: context)
    }

    /// Watches `paths` and tells what happened in a toast.
    static func watch(_ paths: [String], in context: WindowContext) async {
        let app = context.app
        let results = await app.watchFolders(paths)
        if let report = WatchFolderReport(results, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat) {
            context.presenter.show(Toast(
                report.message,
                systemImage: report.tone == .success ? "checkmark.circle.fill" : "info.circle.fill",
                tone: report.tone
            ))
        }
    }
}

/// What watching folders did, and its sentence.
struct WatchFolderReport: Equatable {
    /// What happened.
    enum Outcome: Equatable {
        /// Repositories were added, this many, from these folders.
        case added(Int, from: [String])
        /// Every folder was watched already, and none added any.
        case alreadyWatched([String])
        /// None of the folders had a repository that wasn't in the list.
        case noneNew([String])
    }

    var outcome: Outcome
    var message: String

    var tone: ToastTone {
        if case .added = outcome {
            return .success
        }
        return .notice
    }

    /// The folders that added repositories, when any did; else the folders
    /// that were watched already, when all were; else that the folders had
    /// none that weren't in the list. Nil when nothing was watched.
    ///
    /// - Parameter folders: Every watched folder, for naming them.
    init?(_ results: [WatchedFolderResult], folders: [String], format: NumberFormat) {
        guard !results.isEmpty else {
            return nil
        }
        let names = WatchedFolderNames(folders)
        func list(_ folders: [String]) -> String {
            folders.map(names.name(of:)).formatted(.list(type: .and))
        }
        let adding = results.filter { !$0.added.isEmpty }
        let added = adding.reduce(0) { $0 + $1.added.count }
        if added > 0 {
            let folders = adding.map(\.folder)
            outcome = .added(added, from: folders)
            let count = added == 1 ? "1 repository" : "\(formatCount(added, format)) repositories"
            message = "Added \(count) from \(list(folders))"
        } else if results.allSatisfy(\.wasWatched) {
            let folders = results.map(\.folder)
            outcome = .alreadyWatched(folders)
            message = "Already watching \(list(folders))"
        } else {
            let folders = results.map(\.folder)
            outcome = .noneNew(folders)
            message = "No new repositories in \(list(folders))"
        }
    }
}

/// The watched folders' names: a folder's own name, or where it is (its
/// path, the home folder as `~`) when another watched folder has its name.
struct WatchedFolderNames {
    private let sharedNames: Set<ExactString>

    init(_ folders: [String]) {
        var counts: [ExactString: Int] = [:]
        for folder in folders {
            counts[ExactString(POSIXPath.basename(folder)), default: 0] += 1
        }
        sharedNames = Set(counts.filter { $0.value > 1 }.keys)
    }

    /// The folder's name, or its abbreviated path when it shares the name.
    func name(of folder: String) -> String {
        let name = POSIXPath.basename(folder)
        if name.isEmpty || sharedNames.contains(ExactString(name)) {
            return RepositoryRowContent.abbreviatedPath(folder)
        }
        return name
    }

    /// The folder's own name (its path for `/`).
    static func title(of folder: String) -> String {
        let name = POSIXPath.basename(folder)
        return name.isEmpty ? folder : name
    }
}

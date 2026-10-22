import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "gitignore")

/// What an ignore item adds to the root .gitignore.
public enum GitIgnoreAction: Sendable, Hashable {
    /// Paths relative to the repository (with `/` separators), escaped so
    /// git reads them literally.
    case files([String])
    /// Patterns, added as they are.
    case patterns([String])
}

/// An ignore item of the changes list's context menu, with its copy.
public struct GitIgnoreMenuItem: Sendable, Hashable {
    public let title: String
    public let isEnabled: Bool
    /// What choosing the item adds; nil for a submenu.
    public let action: GitIgnoreAction?
    /// The submenu's items: "Ignore Folder" has one per folder above the
    /// file, innermost first.
    public let submenu: [GitIgnoreMenuItem]

    public init(title: String, isEnabled: Bool = true, action: GitIgnoreAction?, submenu: [GitIgnoreMenuItem] = []) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
        self.submenu = submenu
    }
}

private let gitIgnoreFileName = ".gitignore"

/// The ignore items of the changes list's context menu for the files it
/// applies to: the selected files when the clicked file is one of them,
/// otherwise the clicked file (paths relative to the repository, in that
/// order). The items:
///
/// - one file: "Ignore File (Add to .gitignore)", then, for a file in a
///   folder, "Ignore Folder (Add to .gitignore)" with a submenu of its
///   folders (`/a/b`, `/a`), both disabled for a .gitignore file;
/// - several files: "Ignore N Selected Files (Add to .gitignore)", which
///   leaves out .gitignore files, and is disabled when they are all
///   .gitignore files;
/// - then "Ignore All .ext Files (Add to .gitignore)" for each extension
///   among them, the first five, in order.
public func gitIgnoreMenuItems(for paths: [String]) -> [GitIgnoreMenuItem] {
    var items: [GitIgnoreMenuItem] = []
    let isGitIgnore = { (path: String) in JSCompat.strictEquals(POSIXPath.basename(path), gitIgnoreFileName) }

    if paths.count == 1, let path = paths.first {
        let enabled = !isGitIgnore(path)
        items.append(GitIgnoreMenuItem(
            title: "Ignore File (Add to .gitignore)",
            isEnabled: enabled,
            action: .files([path])
        ))

        // Even on Windows, the path separator is '/' for git operations.
        let pathComponents = Array(JSCompat.split(path, "/").dropLast())
        if !pathComponents.isEmpty {
            let submenu = pathComponents.indices.map { index in
                let label = "/" + pathComponents.prefix(pathComponents.count - index).joined(separator: "/")
                return GitIgnoreMenuItem(title: label, action: .files([label]))
            }
            items.append(GitIgnoreMenuItem(
                title: "Ignore Folder (Add to .gitignore)",
                isEnabled: enabled,
                action: nil,
                submenu: submenu
            ))
        }
    } else if paths.count > 1 {
        // Filter out any .gitignores that happen to be selected; ignoring
        // those doesn't make sense.
        let ignorable = paths.filter { !isGitIgnore($0) }
        items.append(GitIgnoreMenuItem(
            title: "Ignore \(paths.count) Selected Files (Add to .gitignore)",
            isEnabled: !ignorable.isEmpty,
            action: .files(ignorable)
        ))
    }

    // Five menu items should be enough for everyone.
    var extensions: [String] = []
    for path in paths {
        let fileExtension = POSIXPath.extname(path)
        if !fileExtension.isEmpty, !extensions.contains(where: { JSCompat.strictEquals($0, fileExtension) }) {
            extensions.append(fileExtension)
        }
    }
    // The extension is escaped in the rule, as a file's name is: `*.t[x]t`
    // would ignore every .txt file.
    for fileExtension in extensions.prefix(5) {
        items.append(GitIgnoreMenuItem(
            title: "Ignore All \(fileExtension) Files (Add to .gitignore)",
            action: .patterns(["*\(escapeGitSpecialCharacters(fileExtension))"])
        ))
    }

    return items
}

extension RepositoryModel {
    /// The ignore items of the changes list's context menu for `paths`
    /// (`gitIgnoreMenuItems(for:)`); none while a rebase waits on conflicts.
    public func gitIgnoreMenuItems(for paths: [String]) -> [GitIgnoreMenuItem] {
        if case .rebase = operations.conflictState {
            return []
        }
        return EspalierCore.gitIgnoreMenuItems(for: paths)
    }

    /// The root .gitignore's contents, or nil when there is none, for
    /// Repository Settings.
    ///
    /// - Throws: For a symbolic link ("Cannot use a symbolic link as the
    ///   root .gitignore file") or a file that can't be read.
    public func readGitIgnore() async throws(OperationError) -> String? {
        let repository = gitRepository
        do {
            return try await environment.withRuntimes {
                try await readGitIgnoreAtRoot(repository)
            }
        } catch {
            throw await ErrorClassifier.classify(
                error,
                descriptor: OperationDescriptor(kind: .saveGitIgnore, lanes: []),
                record: record,
                context: ClassificationContext()
            )
        }
    }

    /// Replaces the root .gitignore with `text`, or deletes it when `text`
    /// is empty (from Repository Settings). Line endings follow
    /// `core.autocrlf` and `core.safecrlf`. Returns once the changes list
    /// shows the result.
    ///
    /// - Throws: For a symbolic link ("Cannot use a symbolic link as the
    ///   root .gitignore file"), and git's or the file system's errors.
    public func saveGitIgnore(_ text: String) async throws(OperationError) {
        try await performGitIgnoreChange { repository in
            try await GitKit.saveGitIgnore(repository, text)
        }
    }

    /// Adds `action`'s paths or patterns to the root .gitignore, creating it
    /// when needed (from the changes list's context menu). Returns once the
    /// changes list shows the result.
    ///
    /// - Parameter files: The changed files the menu applied to.
    /// - Returns: The paths of the tracked ones among `files` that an ignore
    ///   rule now matches: git keeps tracking them, so their changes still
    ///   show. None when git can't tell.
    /// - Throws: As `saveGitIgnore(_:)`.
    @discardableResult
    public func ignore(_ action: GitIgnoreAction, of files: [WorkingDirectoryFileChange] = []) async throws(OperationError) -> [String] {
        let tracked = files.filter { $0.status.kind != .untracked }.map(\.path)
        let append: @Sendable (Repository) async throws -> Void
        switch action {
        case .files(let paths):
            guard !paths.isEmpty else { return [] }
            append = { repository in try await appendIgnoreFile(repository, paths) }
        case .patterns(let patterns):
            guard !patterns.isEmpty else { return [] }
            append = { repository in try await appendIgnoreRule(repository, patterns) }
        }
        return try await performGitIgnoreChange { repository -> [String] in
            try await append(repository)
            return await ignoredTrackedPaths(tracked, in: repository)
        }
    }

    /// Runs a change of the root .gitignore as an operation in the local
    /// lane, then waits for the status it changes.
    private func performGitIgnoreChange<T: Sendable>(
        _ change: @escaping @Sendable (Repository) async throws -> T
    ) async throws(OperationError) -> T {
        let descriptor = OperationDescriptor(kind: .saveGitIgnore, refreshAfter: .status)
        let result = try await perform(descriptor) { context in
            try await change(context.repository)
        }
        await awaitOperationRefresh(covering: .status)
        return result
    }
}

/// The paths among `tracked` that an ignore rule matches; none when git
/// can't tell.
@concurrent
private func ignoredTrackedPaths(_ tracked: [String], in repository: Repository) async -> [String] {
    guard !tracked.isEmpty else {
        return []
    }
    do {
        let ignored = try await getIgnoredPaths(repository, tracked, includingTracked: true)
        return tracked.filter { ignored.contains(ExactString($0)) }
    } catch {
        logger.error("Could not check which tracked files are ignored: \(String(describing: error), privacy: .private)")
        return []
    }
}

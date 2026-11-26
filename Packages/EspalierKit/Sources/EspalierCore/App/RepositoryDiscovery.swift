// Finding the repositories in a folder, for the watched folders
// (AppModel+WatchedFolders.swift).

import Darwin
import EspalierSupport
import Foundation

/// Finds the repositories in a folder.
public enum RepositoryDiscovery {
    /// How many levels below the folder a scan looks unless told otherwise:
    /// `folder/owner/group/repository` is found.
    public static let defaultMaxDepth = 3

    /// The paths of the repositories in `folder`, at most `maxDepth` levels
    /// below it, each a path under `folder` as given; a folder and its
    /// directories are listed in the order of their names' bytes.
    ///
    /// - A repository is a directory that contains a `.git` directory;
    ///   `folder` itself counts. A directory whose `.git` is anything else
    ///   (a file: a linked worktree or a submodule's checkout) isn't one.
    /// - Nothing inside a repository, or inside a directory with any other
    ///   `.git`, is looked at.
    /// - Symbolic links aren't followed (`folder` itself may be one), and
    ///   hidden directories (a name that starts with a period),
    ///   `node_modules`, `Library`, and bundles such as `.app` are left
    ///   out, with everything in them. A directory that can't be read is
    ///   left out too.
    ///
    /// Runs off the main actor. Once its task is cancelled it stops and
    /// returns what it found until then. A `folder` that isn't an absolute
    /// path, or isn't a directory that can be read, has no repositories.
    @concurrent
    public static func repositories(in folder: String, maxDepth: Int = defaultMaxDepth) async -> [String] {
        guard let root = standardizedAbsolutePath(folder) else {
            return []
        }
        var found: [String] = []
        // The directories to look at, the next one last.
        var pending: [(path: String, depth: Int)] = [(root, 0)]
        while let (path, depth) = pending.popLast() {
            if Task.isCancelled {
                break
            }
            switch gitEntry(in: path) {
            case .directory:
                found.append(path)
                continue
            case .other:
                continue
            case .none:
                break
            }
            guard depth < maxDepth, let names = subdirectories(of: path) else {
                continue
            }
            for name in names.reversed() {
                pending.append((child(name, of: path), depth + 1))
            }
        }
        return found
    }

    /// What a directory has as its `.git`.
    private enum GitEntry {
        /// Nothing, or nothing that can be seen.
        case none
        /// A directory: the directory is a repository.
        case directory
        /// Anything else: a file (a linked worktree, a submodule's
        /// checkout) or a symbolic link.
        case other
    }

    private static func gitEntry(in directory: String) -> GitEntry {
        var info = stat()
        guard lstat(child(".git", of: directory), &info) == 0 else {
            return .none
        }
        return info.st_mode & S_IFMT == S_IFDIR ? .directory : .other
    }

    /// The names of the directories in `directory` that a scan looks at, in
    /// the order of their bytes: no symbolic links, and none of the
    /// directories scans leave out (`isLeftOut`). Nil when `directory`
    /// can't be read.
    private static func subdirectories(of directory: String) -> [String]? {
        guard let stream = opendir(directory) else {
            return nil
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            // A name that isn't UTF-8 has no path as a string.
            let length = Int(entry.pointee.d_namlen)
            let decoded = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(validating: bytes.prefix(length), as: UTF8.self)
            }
            guard let name = decoded, !isHidden(name) else {
                continue
            }
            let path = child(name, of: directory)
            guard isDirectory(entry.pointee.d_type, at: path), !isLeftOut(name, at: path) else {
                continue
            }
            names.append(name)
        }
        names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return names
    }

    /// Whether a directory entry of type `type` is a directory itself, not
    /// a symbolic link to one. A file system that doesn't tell the type
    /// (`DT_UNKNOWN`) is asked about `path`.
    private static func isDirectory(_ type: UInt8, at path: String) -> Bool {
        switch Int32(type) {
        case DT_DIR:
            return true
        case DT_UNKNOWN:
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        default:
            return false
        }
    }

    /// Whether a name is a hidden one: `.` and `..` included.
    private static func isHidden(_ name: String) -> Bool {
        name.utf8.first == UInt8(ascii: ".")
    }

    /// The directories left out by name.
    private static let namesLeftOut: Set<ExactString> = ["node_modules", "Library"].exactSet

    /// Whether scans leave out the directory `name` at `path`:
    /// `node_modules`, `Library`, and bundles. Only a name with an
    /// extension is looked up as a bundle.
    private static func isLeftOut(_ name: String, at path: String) -> Bool {
        if namesLeftOut.contains(ExactString(name)) {
            return true
        }
        guard !POSIXPath.extname(name).isEmpty else {
            return false
        }
        let values = try? URL(exactFilePath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }

    private static func child(_ name: String, of directory: String) -> String {
        JSCompat.endsWith(directory, "/") ? directory + name : directory + "/" + name
    }
}

/// `path` standardized: no `.` or `..`, no repeated or trailing separators.
/// Nil when it isn't absolute. Symbolic links stay as they are.
func standardizedAbsolutePath(_ path: String) -> String? {
    POSIXPath.isAbsolute(path) ? POSIXPath.resolve(path) : nil
}

/// `paths` standardized (`standardizedAbsolutePath`), in order, each once:
/// the ones that aren't absolute, or are the same as an earlier one byte for
/// byte, are dropped.
func standardizedAbsolutePaths(_ paths: [String]) -> [String] {
    var seen: Set<ExactString> = []
    return paths.compactMap { path in
        guard let standardized = standardizedAbsolutePath(path) else {
            return nil
        }
        return seen.insert(ExactString(standardized)).inserted ? standardized : nil
    }
}

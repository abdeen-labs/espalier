// Ported from desktop/app/src/models/repository.ts
//
// Only what GitKit uses: the working directory, the .git directory, and the
// name.

import EspalierSupport

private func getBaseName(_ path: String) -> String {
    let baseName = POSIXPath.basename(path)

    if baseName.isEmpty {
        // the repository is at the root of the drive
        // -> show the full path here to show _something_
        return path
    }

    return baseName
}

/// A local repository.
///
/// Two repositories are equal when their paths are. This ignores `gitDir`,
/// which only caches where `.git` was found.
public struct Repository: Hashable, Sendable {
    /// The working directory of this repository
    public let path: String

    /// The path to the .git directory for this repository, or nil if it
    /// hasn't been resolved yet.
    public let gitDir: String?

    /// The repository's name: the last component of its path, or the whole
    /// path for the root of a volume.
    public let name: String

    public init(path: String, gitDir: String? = nil) {
        self.path = path
        self.gitDir = gitDir
        self.name = getBaseName(path)
    }

    /// The resolved path to the .git directory for this repository.
    ///
    /// Uses the stored gitDir if available, otherwise falls back to
    /// joining the repository path with '.git'.
    public var resolvedGitDir: String {
        gitDir ?? POSIXPath.join(path, ".git")
    }

    public static func == (lhs: Repository, rhs: Repository) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

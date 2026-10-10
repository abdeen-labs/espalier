// Ported from desktop/app/src/lib/get-old-path.ts

/// Resolve the old path (for a rename or a copied change) or default to the
/// current path of a file
public func getOldPathOrDefault(_ file: some FileChange) -> String {
    switch file.status {
    case .renamed(let oldPath, _, _), .copied(let oldPath, _, _):
        oldPath
    case .new, .modified, .deleted, .conflicted, .untracked:
        file.path
    }
}

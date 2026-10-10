// Ported from desktop/app/src/lib/directory-exists.ts

import Foundation

/// Helper method to stat a path and check both that it exists and that it's
/// a directory.
///
/// This follows symbolic links.
public func directoryExists(_ path: String) async -> Bool {
    var info = stat()
    guard stat(path, &info) == 0 else {
        return false
    }
    return (info.st_mode & S_IFMT) == S_IFDIR
}

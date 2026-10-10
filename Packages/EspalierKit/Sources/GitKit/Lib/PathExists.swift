// Ported from desktop/app/src/lib/path-exists.ts

import Foundation

/// Returns a value indicating whether or not the provided path exists (as in
/// whether it's visible to the current process or not).
///
/// This follows symbolic links, so a dangling link does not exist.
public func pathExists(_ path: String) async -> Bool {
    access(path, F_OK) == 0
}

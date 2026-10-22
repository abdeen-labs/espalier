// A folder typed into a sheet's field: a leading `~` is the home folder, as
// in Terminal.

import EspalierSupport
import Foundation

/// `path` with a leading `~`, alone or before a `/`, as `home`; any other
/// path as it is (`~user` included).
public func expandingTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
    if JSCompat.strictEquals(path, "~") {
        return home
    }
    guard JSCompat.startsWith(path, "~/") else {
        return path
    }
    return home + String(path.unicodeScalars.dropFirst())
}

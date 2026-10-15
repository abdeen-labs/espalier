// Ported from desktop/app/src/ui/lib/parse-files-to-be-overwritten.ts

import EspalierSupport

/// The paths git lists after each "error: ... files would be overwritten
/// ...:" line, as in the errors of a checkout, merge, or pull that would
/// overwrite local changes: git lists changed files and untracked ones
/// separately. Empty when the message has no such list.
///
/// Git writes each path after one tab, so a path keeps its own leading
/// whitespace.
public func parseFilesToBeOverwritten(_ errorMessage: String) -> [String] {
    var files: [String] = []
    let lines = JSCompat.split(errorMessage, "\n")

    var inFilesList = false

    for line in lines {
        if inFilesList, JSCompat.startsWith(line, "\t") {
            files.append(JSCompat.dropFirst(line, 1))
        } else {
            inFilesList = JSCompat.startsWith(line, "error:")
                && JSCompat.includes(line, "files would be overwritten")
                && JSCompat.endsWith(line, ":")
        }
    }

    return files
}

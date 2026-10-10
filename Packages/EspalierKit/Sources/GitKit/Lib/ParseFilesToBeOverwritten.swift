// Ported from desktop/app/src/ui/lib/parse-files-to-be-overwritten.ts

import EspalierSupport

/// The paths git lists after an "error: ... files would be overwritten ...:"
/// line, as in the errors of a checkout, merge, or pull that would overwrite
/// local changes. Empty when the message has no such list.
public func parseFilesToBeOverwritten(_ errorMessage: String) -> [String] {
    var files: [String] = []
    let lines = JSCompat.split(errorMessage, "\n")

    var inFilesList = false

    for line in lines {
        if inFilesList {
            if !JSCompat.startsWith(line, "\t") {
                break
            } else {
                files.append(trimmingLeadingWhitespace(line))
            }
        } else {
            if JSCompat.startsWith(line, "error:")
                && JSCompat.includes(line, "files would be overwritten")
                && JSCompat.endsWith(line, ":")
            {
                inFilesList = true
            }
        }
    }

    return files
}

/// JavaScript's `trimLeft()`.
private func trimmingLeadingWhitespace(_ string: String) -> String {
    let scalars = string.unicodeScalars
    guard let first = scalars.firstIndex(where: { !JSCompat.isWhitespace($0) }) else {
        return ""
    }
    return String(scalars[first...])
}

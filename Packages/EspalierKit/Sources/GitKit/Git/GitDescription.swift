// Ported from desktop/app/src/lib/git/description.ts

import EspalierSupport
import Foundation

private let gitDescriptionPath = ".git/description"

public let DefaultGitDescription =
    "Unnamed repository; edit this file 'description' to name the repository.\n"

/// Get the repository's description from the .git/description file.
public func getGitDescription(_ repositoryPath: String) async -> String {
    let path = POSIXPath.join(repositoryPath, gitDescriptionPath)

    guard let data = FileManager.default.contents(atPath: path) else {
        return ""
    }
    let text = String(decoding: data, as: UTF8.self)
    if JSCompat.strictEquals(text, DefaultGitDescription) {
        return ""
    }
    return text
}

/// Write a .git/description file to the repository.
public func writeGitDescription(_ repositoryPath: String, _ description: String) async throws {
    let fullPath = POSIXPath.join(repositoryPath, gitDescriptionPath)
    try Data(description.utf8).write(to: URL(filePath: fullPath))
}

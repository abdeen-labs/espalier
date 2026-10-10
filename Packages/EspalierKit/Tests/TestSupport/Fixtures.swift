// Ported from desktop/app/test/helpers/fixture.ts and the
// `setupFixtureRepository` function in desktop/app/test/helpers/repositories.ts

import Foundation

/// The fixture repositories, kept byte for byte in this module's
/// resources. Fixture repositories store their `.git` folders as `_git` so
/// that the containing repository doesn't treat them as nested repositories.
public enum Fixtures {
    /// The directory that holds every fixture.
    public static let root: URL = {
        guard let url = Bundle.module.url(forResource: "fixtures", withExtension: nil) else {
            fatalError("The fixtures resource is missing from the TestSupport bundle")
        }
        return url
    }()

    /// The path of a file or directory inside the fixtures.
    public static func path(_ components: String...) -> URL {
        components.reduce(root) { $0.appending(path: $1) }
    }
}

/// Copies the named fixture repository to a new temporary directory and
/// renames every `_git` file or folder in it to `.git`.
///
/// - Returns: The path to the set up fixture repository.
public func setupFixtureRepository(_ name: String) throws -> String {
    let fixture = Fixtures.path(name)
    let destination = try TemporaryDirectory.make()
    let fileManager = FileManager.default

    for item in try fileManager.contentsOfDirectory(atPath: fixture.path(percentEncoded: false)) {
        try fileManager.copyItem(at: fixture.appending(path: item), to: destination.appending(path: item))
    }

    // Collect first, then rename deepest paths first, so renaming a parent
    // never invalidates a path collected inside it.
    var renames: [URL] = []
    if let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator where url.lastPathComponent == "_git" {
            renames.append(url)
        }
    }
    for url in renames.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
        try fileManager.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: ".git"))
    }

    return destination.path(percentEncoded: false).trimmingSuffix("/")
}

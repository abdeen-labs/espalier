import Foundation

/// Where Espalier keeps its files.
///
/// Nothing here creates the directories; whoever writes a file creates its
/// directory first.
public struct AppDirectories: Sendable, Hashable {
    /// User data that can't be rebuilt, such as the repository list:
    /// `~/Library/Application Support/Espalier`.
    public var applicationSupport: URL

    /// Data that can be rebuilt and may be deleted at any time, such as
    /// pull request lists: `~/Library/Caches/dev.abdeen.espalier`.
    public var caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    /// The same layout under `root` (`<root>/Application Support/Espalier`
    /// and `<root>/Caches/dev.abdeen.espalier`), for tests.
    public init(root: URL) {
        self.init(
            applicationSupport: root.appending(path: "Application Support", directoryHint: .isDirectory)
                .appending(path: Self.applicationSupportName, directoryHint: .isDirectory),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory)
                .appending(path: Self.defaultBundleIdentifier, directoryHint: .isDirectory)
        )
    }

    /// The user's directories, the caches named after `bundle`'s identifier.
    public static func live(bundle: Bundle = .main) -> AppDirectories {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AppDirectories(
            applicationSupport: support.appending(path: applicationSupportName, directoryHint: .isDirectory),
            caches: caches.appending(path: bundle.bundleIdentifier ?? defaultBundleIdentifier, directoryHint: .isDirectory)
        )
    }

    /// The repository list document (`repositories.json`).
    public var repositoryList: URL {
        applicationSupport.appending(path: "repositories.json", directoryHint: .notDirectory)
    }

    /// The directory for one kind of cache, such as `pull-requests`.
    public func cacheDirectory(_ kind: String) -> URL {
        caches.appending(path: kind, directoryHint: .isDirectory)
    }

    private static let applicationSupportName = "Espalier"
    private static let defaultBundleIdentifier = "dev.abdeen.espalier"
}

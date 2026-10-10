import EspalierCore
import Foundation

/// Records the URLs opened and the paths revealed, opening nothing.
@MainActor
public final class RecordingWorkspace: WorkspaceService {
    public private(set) var openedURLs: [URL] = []
    public private(set) var revealedPaths: [String] = []
    /// What `open` returns.
    public var opens = true

    public init() {}

    public func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return opens
    }

    public func revealInFinder(_ path: String) {
        revealedPaths.append(path)
    }
}

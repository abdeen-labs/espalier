import EspalierCore
import EspalierSupport
import Foundation
import Synchronization
import TestSupport

/// A Trash in a temporary directory, which records what it received and can
/// be made to fail.
public final class TemporaryTrash: TrashService {
    private struct State {
        var trashed: [String] = []
        var isFailing = false
    }

    /// Where trashed items go.
    public let directory: String
    private let state = Mutex(State())

    public init() throws {
        directory = try createTempDirectory(prefix: "espalier-trash-")
    }

    /// The paths moved to the Trash, in order.
    public var trashedPaths: [String] {
        state.withLock { $0.trashed }
    }

    /// Makes every move fail (as when the Trash deletes immediately or
    /// access is restricted), or succeed again.
    public func setFailing(_ failing: Bool) {
        state.withLock { $0.isFailing = failing }
    }

    public func moveToTrash(_ path: String) async throws {
        if state.withLock({ $0.isFailing }) {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        let destination = POSIXPath.join(directory, "\(UUID().uuidString)-\(POSIXPath.basename(path))")
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        state.withLock { $0.trashed.append(path) }
    }
}

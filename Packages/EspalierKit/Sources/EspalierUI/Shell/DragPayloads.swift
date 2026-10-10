// The commits drag payload: the graph table writes
// `dev.abdeen.espalier.commits` (exported in Info.plist, conforming to
// public.data), and the sidebar's branch, New Branch…, and pull request rows
// read it.

import AppKit
import CoreTransferable
import EspalierCore
import GitKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// Commits dragged from the history graph.
    nonisolated public static let espalierCommits = UTType(exportedAs: "dev.abdeen.espalier.commits", conformingTo: .data)
}

/// Commits being dragged: the repository they're in and their SHAs, in the
/// graph's order (newest first).
nonisolated public struct CommitDragPayload: Codable, Sendable, Hashable, Transferable {
    /// The repository's identity (`RepositoryID.rawValue`).
    public let repositoryID: UUID
    public let shas: [String]

    public init(repositoryID: RepositoryID, shas: [String]) {
        self.repositoryID = repositoryID.rawValue
        self.shas = shas
    }

    /// The repository the commits are in.
    public var repository: RepositoryID {
        RepositoryID(rawValue: repositoryID)
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .espalierCommits)
    }

    /// The payload as pasteboard data, for `NSTableView`'s
    /// `pasteboardWriterForRow`.
    public func pasteboardItem() -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.espalierCommits.identifier))
        return item
    }

    /// Reads a payload from a pasteboard (AppKit drop targets).
    public static func read(from pasteboard: NSPasteboard) -> CommitDragPayload? {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.espalierCommits.identifier)) else {
            return nil
        }
        return try? JSONDecoder().decode(CommitDragPayload.self, from: data)
    }
}

/// The commits being dragged in a window, while the drag lasts: the graph's
/// drag source sets `payload` when a drag of commits begins and clears it
/// when the drag ends (`draggingSession(_:endedAt:operation:)`), so drop
/// targets can show themselves before the pointer reaches them (the
/// sidebar's transient "New Branch…" row). One per window:
/// `context.state.featureState(CommitDragState.self) { CommitDragState() }`.
@MainActor @Observable
public final class CommitDragState {
    /// The commits being dragged, or nil when no drag of commits runs.
    public var payload: CommitDragPayload?

    public init() {}
}

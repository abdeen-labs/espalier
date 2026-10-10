// Ported from desktop/app/src/lib/is-application-bundle.ts

import EspalierSupport
import Foundation
import UniformTypeIdentifiers

/// Content types that identify an application bundle, or at least something
/// executable.
private let probableBundleIdentifiers = [
    "com.apple.application-bundle",
    "com.apple.application",
    "public.executable",
]

/// Thrown when a path's metadata identifies neither an application nor a
/// plain directory.
public struct InconclusiveBundleMetadataError: Error, LocalizedError, Sendable, Equatable {
    public init() {}

    public var errorDescription: String? {
        "Metadata did not conclusively identify a directory"
    }
}

/// Attempts to determine if the provided path is an application bundle or
/// not.
///
/// On macOS a directory can also be an application and therefore
/// executable, making it unsafe to open directories as we could
/// conceivably end up launching an application.
///
/// The path's content type is read from the file system, following
/// symbolic links, so the answer doesn't depend on Spotlight's index.
@concurrent
public func isApplicationBundle(_ path: String) async throws -> Bool {
    let url = URL(exactFilePath: path).resolvingSymlinksInPath()
    guard let contentType = try url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
        throw InconclusiveBundleMetadataError()
    }
    return try isApplicationBundle(contentType: contentType)
}

/// The rules for a content type and its tree (the type and every type it
/// conforms to): an application or executable type anywhere in the tree
/// is an application, a plain folder isn't, and anything else is
/// inconclusive.
func isApplicationBundle(contentType: UTType) throws(InconclusiveBundleMetadataError) -> Bool {
    let contentTypeTree = [contentType.identifier] + contentType.supertypes.map(\.identifier)

    if probableBundleIdentifiers.contains(where: contentTypeTree.contains) {
        return true
    }

    if contentType.identifier == UTType.folder.identifier {
        return false
    }

    throw InconclusiveBundleMetadataError()
}

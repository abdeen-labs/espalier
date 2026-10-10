// File URLs for the paths Espalier keeps as strings, which
// `URL(filePath:)` and `URL(fileURLWithPath:)` don't keep byte for byte.

import Foundation

extension URL {
    /// A file URL for `path` that keeps the path's exact bytes, for APIs
    /// that only take URLs (opening a file, selecting it in the Finder,
    /// moving it to the Trash).
    ///
    /// `URL(filePath:)` and `URL(fileURLWithPath:)` decompose non-ASCII
    /// names ("café" becomes "cafe\u{301}"), which names a different file
    /// on a volume that doesn't normalize names, and a different name
    /// everywhere else. This URL's `withUnsafeFileSystemRepresentation`
    /// gives back the UTF-8 bytes of `path` unchanged.
    ///
    /// - Parameters:
    ///   - path: An absolute path.
    ///   - isDirectory: Whether the URL names a directory (a trailing slash).
    public init(exactFilePath path: String, isDirectory: Bool = false) {
        self = path.withCString { pointer in
            URL(fileURLWithFileSystemRepresentation: pointer, isDirectory: isDirectory, relativeTo: nil)
        }
    }
}

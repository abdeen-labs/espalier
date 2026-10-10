// Ported from desktop/app/src/models/diff/image.ts

import Foundation

/// A container for holding an image for display in the application
///
/// Named `DiffImage` because a GitKit type named `Image` would make
/// SwiftUI's `Image` ambiguous in every file that imports both modules.
public struct DiffImage: Hashable, Sendable {
    /// The raw contents of the image.
    public let rawContents: Data
    /// The data URI media type, so the image can be rendered correctly.
    public let mediaType: String
    /// Size of the file in bytes.
    public let bytes: Int

    public init(rawContents: Data, mediaType: String, bytes: Int) {
        self.rawContents = rawContents
        self.mediaType = mediaType
        self.bytes = bytes
    }

    /// The base64 encoded contents of the image, computed from `rawContents`
    /// on demand.
    public var contents: String {
        rawContents.base64EncodedString()
    }
}

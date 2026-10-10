// Ported from desktop/app/src/models/diff/diff-data.ts

import EspalierSupport

public let maximumDiffStringSize = 268_435_441

public enum DiffType: Int, Hashable, Sendable {
    /// Changes to a text file, which may be partially selected for commit
    case text = 0
    /// Changes to a file with a known extension, which can be viewed in the app
    case image = 1
    /// Changes to an unknown file format, which Git is unable to present in a human-friendly format
    case binary = 2
    /// Change to a repository which is included as a submodule of this repository
    case submodule = 3
    /// Diff is large enough to degrade ux if rendered
    case largeText = 4
    /// Diff that will not be rendered
    case unrenderable = 5
}

public enum LineEnding: String, Hashable, Sendable {
    case cr = "CR"
    case lf = "LF"
    case crlf = "CRLF"
}

public struct LineEndingsChange: Hashable, Sendable {
    public let from: LineEnding
    public let to: LineEnding

    public init(from: LineEnding, to: LineEnding) {
        self.from = from
        self.to = to
    }
}

/// Parse the line ending string into an enum value (or `nil` if unknown)
public func parseLineEndingText(_ text: String) -> LineEnding? {
    let input = JSCompat.trim(text)
    switch input {
    case "CR":
        return .cr
    case "LF":
        return .lf
    case "CRLF":
        return .crlf
    default:
        return nil
    }
}

/// Data returned as part of a textual diff
///
/// Shared by `TextDiff` and `LargeTextDiff`.
public protocol TextDiffData: Sendable {
    /// The unified text diff - including headers and context
    var text: String { get }
    /// The diff contents organized by hunk - how the git CLI outputs to the caller
    var hunks: [DiffHunk] { get }
    /// A warning from Git that the line endings have changed in this file and will affect the commit
    var lineEndingsChange: LineEndingsChange? { get }
    /// The largest line number in the diff
    var maxLineNumber: Int { get }
    /// Whether or not the diff has invisible bidi characters
    var hasHiddenBidiChars: Bool { get }
}

public struct TextDiff: TextDiffData, Hashable {
    public let text: String
    public let hunks: [DiffHunk]
    public let lineEndingsChange: LineEndingsChange?
    public let maxLineNumber: Int
    public let hasHiddenBidiChars: Bool

    public init(
        text: String,
        hunks: [DiffHunk],
        lineEndingsChange: LineEndingsChange? = nil,
        maxLineNumber: Int,
        hasHiddenBidiChars: Bool
    ) {
        self.text = text
        self.hunks = hunks
        self.lineEndingsChange = lineEndingsChange
        self.maxLineNumber = maxLineNumber
        self.hasHiddenBidiChars = hasHiddenBidiChars
    }
}

/// Data returned as part of an image diff
public struct ImageDiff: Hashable, Sendable {
    /// The previous image, if the file was modified or deleted
    ///
    /// Will be nil for an added image
    public let previous: DiffImage?
    /// The current image, if the file was added or modified
    ///
    /// Will be nil for a deleted image
    public let current: DiffImage?

    public init(previous: DiffImage? = nil, current: DiffImage? = nil) {
        self.previous = previous
        self.current = current
    }
}

public struct SubmoduleDiff: Hashable, Sendable {
    /// Full path of the submodule
    public let fullPath: String

    /// Path of the repository within its container repository
    public let path: String

    /// URL of the submodule
    public let url: String?

    /// Status of the submodule
    public let status: SubmoduleStatus

    /// Previous SHA of the submodule, or nil if it hasn't changed
    public let oldSHA: String?

    /// New SHA of the submodule, or nil if it hasn't changed
    public let newSHA: String?

    public init(
        fullPath: String,
        path: String,
        url: String?,
        status: SubmoduleStatus,
        oldSHA: String?,
        newSHA: String?
    ) {
        self.fullPath = fullPath
        self.path = path
        self.url = url
        self.status = status
        self.oldSHA = oldSHA
        self.newSHA = newSHA
    }
}

public struct LargeTextDiff: TextDiffData, Hashable {
    public let text: String
    public let hunks: [DiffHunk]
    public let lineEndingsChange: LineEndingsChange?
    public let maxLineNumber: Int
    public let hasHiddenBidiChars: Bool

    public init(
        text: String,
        hunks: [DiffHunk],
        lineEndingsChange: LineEndingsChange? = nil,
        maxLineNumber: Int,
        hasHiddenBidiChars: Bool
    ) {
        self.text = text
        self.hunks = hunks
        self.lineEndingsChange = lineEndingsChange
        self.maxLineNumber = maxLineNumber
        self.hasHiddenBidiChars = hasHiddenBidiChars
    }
}

/// The union of diff types that can be rendered in the app
///
/// The case is its `kind`. `.binary` and `.unrenderable` carry nothing but
/// their kind.
public enum Diff: Hashable, Sendable {
    case text(TextDiff)
    case image(ImageDiff)
    case binary
    case submodule(SubmoduleDiff)
    case largeText(LargeTextDiff)
    case unrenderable

    public var kind: DiffType {
        switch self {
        case .text: .text
        case .image: .image
        case .binary: .binary
        case .submodule: .submodule
        case .largeText: .largeText
        case .unrenderable: .unrenderable
        }
    }
}

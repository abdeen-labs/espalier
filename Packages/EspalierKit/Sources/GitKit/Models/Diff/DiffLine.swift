// Ported from desktop/app/src/models/diff/diff-line.ts

/// indicate what a line in the diff represents
import EspalierSupport

public enum DiffLineType: Int, Hashable, Sendable {
    case context = 0
    case add = 1
    case delete = 2
    case hunk = 3
}

/// track details related to each line in the diff
public struct DiffLine: Hashable, Sendable {
    public let text: String
    public let type: DiffLineType
    /// Line number in the original diff patch (before expanding it), or nil if
    /// it was added as part of a diff expansion action.
    public let originalLineNumber: Int?
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let noTrailingNewLine: Bool

    public init(
        text: String,
        type: DiffLineType,
        originalLineNumber: Int?,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        noTrailingNewLine: Bool = false
    ) {
        self.text = text
        self.type = type
        self.originalLineNumber = originalLineNumber
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.noTrailingNewLine = noTrailingNewLine
    }

    public func withNoTrailingNewLine(_ noTrailingNewLine: Bool) -> DiffLine {
        DiffLine(
            text: text,
            type: type,
            originalLineNumber: originalLineNumber,
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber,
            noTrailingNewLine: noTrailingNewLine
        )
    }

    public func isIncludeableLine() -> Bool {
        type == .add || type == .delete
    }

    /// The content of the line, i.e., without the line type marker.
    public var content: String {
        JSCompat.dropFirst(text, 1)
    }
}

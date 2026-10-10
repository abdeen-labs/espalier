// Ported in part from desktop/app/src/ui/diff/syntax-highlighting/index.ts
//
// Syntax color for diffs. Whole files are highlighted (the old and new
// contents the diff contents loader reads), only the lines the diff shows
// are asked for, and the tokens are then looked up by each diff line's
// number. Highlighting runs off the main actor after the diff has painted;
// the table redraws its visible rows when the tokens arrive.
//
// The highlighter itself is pluggable: `SyntaxHighlighter` is the seam the
// tree-sitter highlighter implements. Until one is set, diffs show no
// syntax color.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import os
import SwiftUI

nonisolated private let logger = Log.logger(category: "diff")

/// The eight token styles (`TokenTheme` gives their colors).
nonisolated public enum TokenStyle: UInt8, Sendable, CaseIterable, Hashable {
    case keyword
    case string
    case comment
    case number
    /// Type names.
    case type
    /// Function and method names.
    case function
    /// Operators and punctuation.
    case operatorOrPunctuation
    /// Everything else (identifiers, plain text).
    case plain
}

/// A token in a line of a file: a range of the line's UTF-16 code units.
nonisolated public struct SyntaxToken: Sendable, Hashable {
    /// The code units, in the line (without its line ending).
    public var range: Range<Int>
    public var style: TokenStyle

    public init(range: Range<Int>, style: TokenStyle) {
        self.range = range
        self.style = style
    }
}

/// What to highlight: one version of a file.
nonisolated public struct HighlightRequest: Sendable {
    /// The file's lines, without line endings.
    public var lines: [String]
    /// The file's path in the repository; its name and extension pick the
    /// language.
    public var path: String
    /// The tab width.
    public var tabSize: Int
    /// The zero-based lines the diff shows; a highlighter may skip the
    /// rest, but still has to parse what comes before them.
    public var lineFilter: Set<Int>

    public init(lines: [String], path: String, tabSize: Int, lineFilter: Set<Int>) {
        self.lines = lines
        self.path = path
        self.tabSize = tabSize
        self.lineFilter = lineFilter
    }

    /// The file's name.
    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// The file's extension, with its dot, or "".
    public var fileExtension: String {
        let pathExtension = (fileName as NSString).pathExtension
        return pathExtension.isEmpty ? "" : "." + pathExtension
    }
}

/// Highlights files. Implementations run off the main actor and should
/// stop early when their task is cancelled.
public protocol SyntaxHighlighter: Sendable {
    /// The tokens of the lines `request.lineFilter` names, keyed by their
    /// zero-based line index. A language the highlighter doesn't know gives
    /// no tokens.
    func tokens(for request: HighlightRequest) async -> [Int: [SyntaxToken]]
}

/// The tokens of both versions of a file, by zero-based line index.
nonisolated public struct FileTokens: Sendable, Equatable {
    public var oldTokens: [Int: [SyntaxToken]]
    public var newTokens: [Int: [SyntaxToken]]

    public init(oldTokens: [Int: [SyntaxToken]] = [:], newTokens: [Int: [SyntaxToken]] = [:]) {
        self.oldTokens = oldTokens
        self.newTokens = newTokens
    }

    public static let none = FileTokens()

    public var isEmpty: Bool {
        oldTokens.isEmpty && newTokens.isEmpty
    }

    /// Attempt to get tokens for a particular diff line. Line numbers start
    /// at one; the tokens are indexed from zero.
    func tokens(lineNumber: Int, in tokens: [Int: [SyntaxToken]]) -> [SyntaxToken]? {
        guard lineNumber > 0 else {
            return nil
        }
        return tokens[lineNumber - 1]
    }

    /// The tokens for a diff line: a deleted line's from the old file, an
    /// added line's from the new one, and a context line's from whichever
    /// has them (the old file first).
    func tokens(for line: DocumentLine) -> [SyntaxToken]? {
        switch line.type {
        case .delete:
            tokens(lineNumber: line.oldNumber, in: oldTokens)
        case .add:
            tokens(lineNumber: line.newNumber, in: newTokens)
        case .context:
            tokens(lineNumber: line.oldNumber, in: oldTokens) ?? tokens(lineNumber: line.newNumber, in: newTokens)
        case .hunk:
            nil
        }
    }
}

/// Which lines need tokens in the old and new versions of a file.
nonisolated struct LineFilters: Sendable, Equatable {
    var oldLineFilter: [Int]
    var newLineFilter: [Int]
}

/// Figure out which lines we need to have tokenized in both the old and new
/// version of the file.
nonisolated func getLineFilters(_ hunks: [DiffHunk]) -> LineFilters {
    var oldLineFilter: [Int] = []
    var newLineFilter: [Int] = []

    var anyAdded = false
    var anyDeleted = false

    for hunk in hunks {
        for line in hunk.lines {
            anyAdded = anyAdded || line.type == .add
            anyDeleted = anyDeleted || line.type == .delete
        }
    }

    for hunk in hunks {
        for line in hunk.lines {
            // So this might need a little explaining. What we're trying
            // to achieve here is if the diff contains only additions or
            // only deletions we'll source all the highlighted lines from
            // either the before or after file. That way we can completely
            // disregard highlighting, the other version.
            if let oldLineNumber = line.oldLineNumber, let newLineNumber = line.newLineNumber {
                if anyAdded, !anyDeleted {
                    newLineFilter.append(newLineNumber - 1)
                } else {
                    oldLineFilter.append(oldLineNumber - 1)
                }
            } else {
                // If there's a mix (meaning we'll have to read from both
                // anyway) we'll prioritize the old version since
                // that's immutable and less likely to be the subject of a
                // race condition when someone rapidly modifies the file on
                // disk.
                if let oldLineNumber = line.oldLineNumber {
                    oldLineFilter.append(oldLineNumber - 1)
                } else if let newLineNumber = line.newLineNumber {
                    newLineFilter.append(newLineNumber - 1)
                }
            }
        }
    }

    return LineFilters(oldLineFilter: oldLineFilter, newLineFilter: newLineFilter)
}

/// Highlights both versions of a file for a diff. Off the main actor;
/// versions the file doesn't have give no tokens.
@concurrent
nonisolated func highlightContents(
    _ contents: DiffFileContents,
    path: String,
    oldPath: String,
    hunks: [DiffHunk],
    tabSize: Int,
    highlighter: any SyntaxHighlighter
) async -> FileTokens {
    let filters = getLineFilters(hunks)
    async let oldTokens: [Int: [SyntaxToken]] = contents.oldLines.isEmpty || filters.oldLineFilter.isEmpty
        ? [:]
        : highlighter.tokens(for: HighlightRequest(lines: contents.oldLines, path: oldPath, tabSize: tabSize, lineFilter: Set(filters.oldLineFilter)))
    async let newTokens: [Int: [SyntaxToken]] = contents.newLines.isEmpty || filters.newLineFilter.isEmpty
        ? [:]
        : highlighter.tokens(for: HighlightRequest(lines: contents.newLines, path: path, tabSize: tabSize, lineFilter: Set(filters.newLineFilter)))
    let result = await FileTokens(oldTokens: oldTokens, newTokens: newTokens)
    logger.debug("Highlighted \(result.oldTokens.count + result.newTokens.count, privacy: .public) lines")
    return result
}

/// The app's syntax highlighter, which diffs use unless the environment
/// sets another (`EnvironmentValues.syntaxHighlighter`). Nil until a
/// highlighter is installed at launch.
@MainActor
public enum SyntaxHighlighting {
    public static var defaultHighlighter: (any SyntaxHighlighter)?
}

extension EnvironmentValues {
    /// The syntax highlighter diffs use, overriding
    /// `SyntaxHighlighting.defaultHighlighter` (tests set it).
    @Entry public var syntaxHighlighter: (any SyntaxHighlighter)? = nil
}

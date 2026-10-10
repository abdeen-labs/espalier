// Ported from desktop/app/src/lib/diff-parser.ts
//
// This parses the UTF-8 bytes, so a multi-megabyte diff is never indexed by
// `Character`. Every boundary the parser looks for (newlines, line prefixes,
// the hunk header, the "no newline" marker) is ASCII, and an ASCII byte
// always decodes to itself and ends any invalid sequence before it, so
// decoding each piece separately gives exactly the text sliced out of the
// decoded whole. Lengths are measured in UTF-16 code units, as JavaScript
// measures them.

import EspalierSupport
import Foundation

// https://en.wikipedia.org/wiki/Diff_utility
//
// @@ -l,s +l,s @@ optional section heading
//
// The hunk range information contains two hunk ranges. The range for the hunk of the original
// file is preceded by a minus symbol, and the range for the new file is preceded by a plus
// symbol. Each hunk range is of the format l,s where l is the starting line number and s is
// the number of lines the change hunk applies to for each respective file.
//
// In many versions of GNU diff, each range can omit the comma and trailing value s,
// in which case s defaults to 1
//
// const diffHeaderRe = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
// (matched by `parseHunkHeader` below)

/// Regular expression matching invisible bidirectional Unicode characters that
/// may be interpreted or compiled differently than what it appears. More info:
/// https://github.co/hiddenchars
public let HiddenBidiCharsRegex = JSCompat.regex(#"[‪-‮]|[⁦-⁩]"#)

/// `HiddenBidiCharsRegex.test(text)`, without a regular expression.
public func containsHiddenBidiChars(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
}

private let DiffPrefixAdd = UInt8(ascii: "+")
private let DiffPrefixDelete = UInt8(ascii: "-")
private let DiffPrefixContext = UInt8(ascii: " ")
private let DiffPrefixNoNewline = UInt8(ascii: "\\")

/// A parser for the GNU unified diff format
///
/// See https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html
///
/// It keeps its state in each `parse` call, so it can be shared.
public struct DiffParser: Sendable {
    public init() {}

    /// Parse a well-formed unified diff into hunks and lines.
    ///
    /// - Parameter text: A unified diff produced by git diff, git log --patch
    ///   or any other git plumbing command that produces unified diffs.
    /// - Throws: `GitLibError` when the diff is malformed.
    public func parse(_ text: String) throws -> RawDiff {
        var text = text
        return try text.withUTF8 { bytes in
            var state = DiffParserState(text: bytes)
            return try state.parse()
        }
    }

    /// Parse the bytes of a well-formed unified diff, decoded as UTF-8
    /// (invalid sequences become U+FFFD).
    public func parse(_ data: Data) throws -> RawDiff {
        try data.withUnsafeBytes { raw in
            try parse(raw.bindMemory(to: UInt8.self))
        }
    }

    /// Parse the bytes of a well-formed unified diff.
    public func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> RawDiff {
        var state = DiffParserState(text: bytes)
        return try state.parse()
    }
}

/// The state of one parse.
private struct DiffParserState {
    /// Line start pointer.
    ///
    /// The offset into the text property where the current line starts (ie either zero
    /// or one character ahead of the last newline character).
    var ls = 0

    /// Line end pointer.
    ///
    /// The offset into the text property where the current line ends (ie it points to
    /// the newline character) or -1 if the line boundary hasn't been determined yet
    var le = -1

    /// The text buffer containing the raw, unified diff output to be parsed
    let text: UnsafeBufferPointer<UInt8>

    init(text: UnsafeBufferPointer<UInt8>) {
        self.text = text
    }

    /// Aligns the internal character pointers at the boundaries of
    /// the next line.
    ///
    /// Returns true if successful or false if the end of the diff
    /// has been reached.
    mutating func nextLine() -> Bool {
        ls = le + 1

        // We've reached the end of the diff
        if ls >= text.count {
            return false
        }

        // If we can't find the next newline character we'll put our
        // end pointer at the end of the diff string
        le = indexOf(UInt8(ascii: "\n"), from: ls) ?? text.count

        // We've succeeded if there's anything to read in between the
        // start and the end
        return ls != le
    }

    /// Advances to the next line and returns its range in the raw diff text.
    /// Returns nil if end of diff was reached.
    mutating func readLine() -> Range<Int>? {
        nextLine() ? ls..<le : nil
    }

    /// Tests if the current line starts with the given search text
    func lineStartsWith(_ searchString: [UInt8]) -> Bool {
        let end = ls + searchString.count
        guard ls >= 0, end <= text.count else {
            return false
        }
        return text[ls..<end].elementsEqual(searchString)
    }

    /// Tests if the current line ends with the given search text
    func lineEndsWith(_ searchString: [UInt8]) -> Bool {
        let start = le - searchString.count
        guard start >= 0, le <= text.count else {
            return false
        }
        return text[start..<le].elementsEqual(searchString)
    }

    /// Returns the starting character of the next line without
    /// advancing the internal state. Returns nil if advancing
    /// would mean reaching the end of the diff.
    func peek() -> UInt8? {
        let p = le + 1
        return p < text.count ? text[p] : nil
    }

    /// Parse the diff header, meaning everything from the
    /// start of the diff output to the end of the line beginning
    /// with +++
    ///
    /// Example diff header:
    ///
    ///     diff --git a/app/src/lib/diff-parser.ts b/app/src/lib/diff-parser.ts
    ///     index e1d4871..3bd3ee0 100644
    ///     --- a/app/src/lib/diff-parser.ts
    ///     +++ b/app/src/lib/diff-parser.ts
    ///
    /// Returns whether the header marks a binary patch, or nil if the end of
    /// the diff was reached before the +++ line could be found (which is a
    /// valid state).
    mutating func parseDiffHeader() -> Bool? {
        while nextLine() {
            if lineStartsWith(binaryFilesPrefix), lineEndsWith(differSuffix) {
                return true
            }

            if lineStartsWith(newFilePrefix) {
                return false
            }
        }

        // It's not an error to not find the +++ line: the diff of an empty
        // file has none.
        return nil
    }

    /// Parses a hunk header or throws an error if the given line isn't
    /// a well-formed hunk header.
    ///
    /// We currently only extract the line number information and
    /// ignore any hunk headings.
    ///
    /// Example hunk header (text within ``):
    ///
    /// `@@ -84,10 +82,8 @@ export function parseRawDiff(lines: ReadonlyArray<string>): Diff {`
    ///
    /// Where everything after the last @@ is what's known as the hunk, or section, heading
    func parseHunkHeader(_ line: Range<Int>) throws -> DiffHunkHeader {
        // `diffHeaderRe`, matched field by field. Each run of digits must be
        // followed by a fixed character, so there's only one way to match.
        var position = line.lowerBound

        func expect(_ bytes: [UInt8]) -> Bool {
            let end = position + bytes.count
            guard end <= line.upperBound, text[position..<end].elementsEqual(bytes) else {
                return false
            }
            position = end
            return true
        }

        func digits() -> Range<Int>? {
            let start = position
            while position < line.upperBound, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[position]) {
                position += 1
            }
            return position > start ? start..<position : nil
        }

        /// `(?:,(\d+))?`
        func optionalCount() -> Range<Int>? {
            let start = position
            if expect(comma), let count = digits() {
                return count
            }
            position = start
            return nil
        }

        guard expect(hunkHeaderStart), let oldStart = digits() else {
            throw GitLibError("Invalid hunk header format")
        }
        let oldCount = optionalCount()
        guard expect(hunkHeaderNewRange), let newStart = digits() else {
            throw GitLibError("Invalid hunk header format")
        }
        let newCount = optionalCount()
        guard expect(hunkHeaderEnd) else {
            throw GitLibError("Invalid hunk header format")
        }

        // If endLines are missing default to 1, see diffHeaderRe docs
        let oldStartLine = try numberFromGroup(oldStart, 1)
        let oldLineCount = try oldCount.map { try numberFromGroup($0, 2) } ?? 1
        let newStartLine = try numberFromGroup(newStart, 3)
        let newLineCount = try newCount.map { try numberFromGroup($0, 4) } ?? 1

        return DiffHunkHeader(
            oldStartLine: oldStartLine,
            oldLineCount: oldLineCount,
            newStartLine: newStartLine,
            newLineCount: newLineCount
        )
    }

    /// Converts a captured run of digits into a number, or throws if the
    /// captured string can't be converted to a number.
    ///
    /// Digits only fail to convert when the number is too large for `Int`,
    /// which can't be a line number either.
    func numberFromGroup(_ digits: Range<Int>, _ group: Int) throws -> Int {
        var value = 0
        for index in digits {
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: 10)
            let (added, overflowAdd) = multiplied.addingReportingOverflow(Int(text[index] - UInt8(ascii: "0")))
            if overflow || overflowAdd {
                throw GitLibError("Could not parse capture group \(group) into number: \(string(digits))")
            }
            value = added
        }
        return value
    }

    /// Checks to see if the given character is one of the allowed prefix
    /// characters for diff lines (ie lines in between hunk headers).
    func parseLinePrefix(_ c: UInt8?) -> UInt8? {
        switch c {
        case DiffPrefixAdd, DiffPrefixDelete, DiffPrefixContext, DiffPrefixNoNewline:
            c
        default:
            nil
        }
    }

    /// Parses a hunk, including its header or throws an error if the diff doesn't
    /// contain a well-formed diff hunk at the current position.
    ///
    /// Expects that the position has been advanced to the beginning of a presumed
    /// diff hunk header.
    ///
    /// - Parameter linesConsumed: The number of unified diff lines consumed up until
    ///   this point by the diff parser. Used to give the
    ///   position and length (in lines) of the parsed hunk
    ///   relative to the overall parsed diff. These numbers
    ///   have no real meaning in the context of a diff and
    ///   are only used to aid the app in line-selections.
    mutating func parseHunk(_ linesConsumed: Int, _ hunkIndex: Int, _ previousHunk: DiffHunk?) throws -> DiffHunk {
        guard let headerLine = readLine() else {
            throw GitLibError("Expected hunk header but reached end of diff")
        }

        let header = try parseHunkHeader(headerLine)
        var lines: [DiffLine] = []
        lines.append(DiffLine(text: string(headerLine), type: .hunk, originalLineNumber: 1, oldLineNumber: nil, newLineNumber: nil))

        var rollingDiffBeforeCounter = header.oldStartLine
        var rollingDiffAfterCounter = header.newStartLine

        var diffLineNumber = linesConsumed
        while let c = parseLinePrefix(peek()) {
            guard let line = readLine() else {
                throw GitLibError("Expected unified diff line but reached end of diff")
            }

            // A marker indicating that the last line in the original or the new file
            // is missing a trailing newline. In other words, the presence of this marker
            // means that the new and/or original file lacks a trailing newline.
            //
            // When we find it we have to look up the previous line and set the
            // noTrailingNewLine flag
            if c == DiffPrefixNoNewline {
                // See https://github.com/git/git/blob/21f862b498925194f8f1ebe8203b7a7df756555b/apply.c#L1725-L1732
                // (the length is measured in UTF-16 code units)
                if line.count < 12 || string(line).utf16.count < 12 {
                    throw GitLibError(#"Expected "no newline at end of file" marker to be at least 12 bytes long"#)
                }

                let previousLineIndex = lines.count - 1
                lines[previousLineIndex] = lines[previousLineIndex].withNoTrailingNewLine(true)

                continue
            }

            // We must increase `diffLineNumber` only when we're certain that the line
            // is not a "no newline" marker. Otherwise, we'll end up with a wrong
            // `diffLineNumber` for the next line. This could happen if the last line
            // in the file doesn't have a newline before the change.
            diffLineNumber += 1

            let diffLine: DiffLine

            if c == DiffPrefixAdd {
                diffLine = DiffLine(
                    text: string(line),
                    type: .add,
                    originalLineNumber: diffLineNumber,
                    oldLineNumber: nil,
                    newLineNumber: rollingDiffAfterCounter
                )
                rollingDiffAfterCounter += 1
            } else if c == DiffPrefixDelete {
                diffLine = DiffLine(
                    text: string(line),
                    type: .delete,
                    originalLineNumber: diffLineNumber,
                    oldLineNumber: rollingDiffBeforeCounter,
                    newLineNumber: nil
                )
                rollingDiffBeforeCounter += 1
            } else {
                diffLine = DiffLine(
                    text: string(line),
                    type: .context,
                    originalLineNumber: diffLineNumber,
                    oldLineNumber: rollingDiffBeforeCounter,
                    newLineNumber: rollingDiffAfterCounter
                )
                rollingDiffBeforeCounter += 1
                rollingDiffAfterCounter += 1
            }

            lines.append(diffLine)
        }

        if lines.count == 1 {
            throw GitLibError("Malformed diff, empty hunk")
        }

        return DiffHunk(
            header: header,
            lines: lines,
            unifiedDiffStart: linesConsumed,
            unifiedDiffEnd: linesConsumed + lines.count - 1,
            expansionType: getHunkHeaderExpansionType(hunkIndex, header, previousHunk)
        )
    }

    /// Parse a well-formed unified diff into hunks and lines.
    mutating func parse() throws -> RawDiff {
        let headerInfo = parseDiffHeader()

        let headerEnd = le
        let header = string(jsSubstring(0, headerEnd))

        // empty diff
        guard let isBinary = headerInfo else {
            return RawDiff(
                header: header,
                contents: "",
                hunks: [],
                isBinary: false,
                maxLineNumber: 0,
                hasHiddenBidiChars: false
            )
        }

        if isBinary {
            return RawDiff(
                header: header,
                contents: "",
                hunks: [],
                isBinary: true,
                maxLineNumber: 0,
                hasHiddenBidiChars: false
            )
        }

        var hunks: [DiffHunk] = []
        var linesConsumed = 0
        var previousHunk: DiffHunk?

        repeat {
            let hunk = try parseHunk(linesConsumed, hunks.count, previousHunk)
            hunks.append(hunk)
            previousHunk = hunk
            linesConsumed += hunk.lines.count
        } while peek() != nil

        // Without any "\n\ No newline at end of file" marker.
        let contents = removingNoNewlineMarkers(jsSubstring(headerEnd + 1, le))

        return RawDiff(
            header: header,
            contents: contents,
            hunks: hunks,
            isBinary: isBinary,
            maxLineNumber: getLargestLineNumber(hunks),
            hasHiddenBidiChars: containsHiddenBidiChars(text)
        )
    }

    // MARK: Helpers

    /// The text of a byte range, decoded as UTF-8 with replacement characters.
    func string(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: text[range]), as: UTF8.self)
    }

    /// JavaScript's `text.substring(start, end)`: clamped to the text, with
    /// the bounds swapped when `start` is after `end`.
    func jsSubstring(_ start: Int, _ end: Int) -> Range<Int> {
        let a = min(max(start, 0), text.count)
        let b = min(max(end, 0), text.count)
        return min(a, b)..<max(a, b)
    }

    func indexOf(_ byte: UInt8, from start: Int) -> Int? {
        guard let base = text.baseAddress, start < text.count,
              let found = memchr(base + start, Int32(byte), text.count - start)
        else {
            return nil
        }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }

    /// The text of `range` with every "\n\ No newline at end of file"
    /// removed. Matches are on the bytes, and each piece in between is
    /// decoded on its own, which is the same as decoding first: the marker
    /// is ASCII and starts with a newline.
    func removingNoNewlineMarkers(_ range: Range<Int>) -> String {
        guard let base = text.baseAddress, !range.isEmpty else {
            return ""
        }

        var result = ""
        var segmentStart = range.lowerBound
        while segmentStart < range.upperBound,
              let found = noNewlineMarker.withUnsafeBytes({ marker in
                  memmem(base + segmentStart, range.upperBound - segmentStart, marker.baseAddress, marker.count)
              }) {
            let markerStart = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            result += string(segmentStart..<markerStart)
            segmentStart = markerStart + noNewlineMarker.count
        }

        if segmentStart == range.lowerBound {
            return string(range)
        }
        result += string(segmentStart..<range.upperBound)
        return result
    }
}

private let binaryFilesPrefix = Array("Binary files ".utf8)
private let differSuffix = Array("differ".utf8)
private let newFilePrefix = Array("+++".utf8)
private let hunkHeaderStart = Array("@@ -".utf8)
private let hunkHeaderNewRange = Array(" +".utf8)
private let hunkHeaderEnd = Array(" @@".utf8)
private let comma = Array(",".utf8)
private let noNewlineMarker = Array("\n\\ No newline at end of file".utf8)

/// `HiddenBidiCharsRegex.test(text)` on the decoded bytes. U+202A to U+202E
/// are E2 80 AA to E2 80 AE in UTF-8, and U+2066 to U+2069 are E2 81 A6 to
/// E2 81 A9. A lead byte always starts a new character, so these bytes
/// decode to exactly those characters.
private func containsHiddenBidiChars(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let base = text.baseAddress else {
        return false
    }
    var index = 0
    while index < text.count, let found = memchr(base + index, 0xE2, text.count - index) {
        let lead = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        if lead + 2 < text.count {
            let second = text[lead + 1]
            let third = text[lead + 2]
            if (second == 0x80 && (0xAA...0xAE).contains(third)) || (second == 0x81 && (0xA6...0xA9).contains(third)) {
                return true
            }
        }
        index = lead + 1
    }
    return false
}

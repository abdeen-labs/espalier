// A file's lines as tree-sitter reads them, in UTF-16 code units (the unit
// the diff's tokens use), with where each line starts, and parsing with
// cancellation.

import TreeSitter

/// A file's lines joined with newlines (and one after the last), in UTF-16.
struct SourceText {
    /// The code units.
    let units: [UInt16]
    /// Where each line starts, plus `units.count` at the end.
    let lineStarts: [Int]

    init(lines: [String]) {
        var count = 0
        for line in lines {
            count += line.utf16.count + 1
        }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count + 1)
        for line in lines {
            lineStarts.append(units.count)
            units.append(contentsOf: line.utf16)
            units.append(0x0A)
        }
        lineStarts.append(units.count)
        self.units = units
        self.lineStarts = lineStarts
    }

    var lineCount: Int {
        lineStarts.count - 1
    }

    /// The line's code units, without its newline.
    func lineRange(_ line: Int) -> Range<Int> {
        lineStarts[line]..<(lineStarts[line + 1] - 1)
    }

    /// The line holding `unit` (the last line for the final newline).
    func line(containing unit: Int) -> Int {
        var low = 0
        var high = lineCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= unit {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The (row, column) point of a code unit offset, with columns in bytes
    /// of UTF-16, as tree-sitter counts them for UTF-16 input.
    func point(at unit: Int) -> TSPoint {
        let row = line(containing: unit)
        return TSPoint(row: UInt32(row), column: UInt32((unit - lineStarts[row]) * 2))
    }

    /// Whether the code units in `range` equal `other`.
    func text(_ range: Range<Int>, equals other: [UInt16]) -> Bool {
        guard range.count == other.count else {
            return false
        }
        return units.withUnsafeBufferPointer { buffer in
            var index = 0
            for unit in range {
                if buffer[unit] != other[index] {
                    return false
                }
                index += 1
            }
            return true
        }
    }

    /// The text in `range`, as a string.
    func string(_ range: Range<Int>) -> String {
        units.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeBufferPointer(rebasing: buffer[range]), as: UTF16.self)
        }
    }

    /// Parses the first `unitCount` code units (or, with `ranges`, only
    /// those ranges) with `language`. Throws `CancellationError` when the
    /// task is cancelled while parsing.
    func parse(
        with parser: ParserHandle,
        language: LanguageHandle,
        unitCount: Int? = nil,
        ranges: [TSRange]? = nil
    ) throws -> TreeHandle {
        guard ts_parser_set_language(parser.pointer, language.pointer) else {
            throw HighlightError.incompatibleLanguage
        }
        if let ranges {
            let accepted = ranges.withUnsafeBufferPointer { buffer in
                ts_parser_set_included_ranges(parser.pointer, buffer.baseAddress, UInt32(buffer.count))
            }
            guard accepted else {
                throw HighlightError.invalidRanges
            }
        } else {
            ts_parser_set_included_ranges(parser.pointer, nil, 0)
        }
        let byteCount = min(unitCount ?? units.count, units.count) * 2
        let tree = units.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            var context = InputContext(base: UnsafeRawPointer(buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!), byteCount: byteCount)
            return withUnsafeMutablePointer(to: &context) { contextPointer in
                let input = TSInput(
                    payload: UnsafeMutableRawPointer(contextPointer),
                    read: { payload, byteIndex, _, bytesRead in
                        let context = payload!.assumingMemoryBound(to: InputContext.self).pointee
                        let index = Int(byteIndex)
                        guard index < context.byteCount else {
                            bytesRead?.pointee = 0
                            return context.base.assumingMemoryBound(to: CChar.self)
                        }
                        bytesRead?.pointee = UInt32(context.byteCount - index)
                        return (context.base + index).assumingMemoryBound(to: CChar.self)
                    },
                    encoding: TSInputEncodingUTF16LE,
                    decode: nil
                )
                let options = TSParseOptions(payload: nil, progress_callback: { _ in
                    Task.isCancelled
                })
                return ts_parser_parse_with_options(parser.pointer, nil, input, options)
            }
        }
        guard let tree else {
            // A parse stops early only when the progress callback asks.
            ts_parser_reset(parser.pointer)
            throw CancellationError()
        }
        return TreeHandle(tree)
    }
}

/// What the input callback reads from.
private struct InputContext {
    var base: UnsafeRawPointer
    var byteCount: Int
}

/// Why a file couldn't be highlighted.
public enum HighlightError: Error, Equatable, Sendable {
    /// A grammar's queries are missing or don't compile.
    case queries(grammar: String, reason: String)
    /// The grammar was generated for an ABI this tree-sitter doesn't read.
    case incompatibleLanguage
    /// Injected ranges were out of order.
    case invalidRanges
}

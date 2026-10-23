// A conflicted file's text, divided by the conflict markers git reports in
// it (`getConflictMarkerLines(_:path:)`) into the lines outside conflicts
// and each conflict's sides: ours, the common ancestor's (the diff3 and
// zdiff3 styles' `|||||||` section), and theirs. Git finds markers of the
// size the path's `conflict-marker-size` attribute sets, so a marker is a
// line git reported, and its first character says which it is, whatever
// its size (as `countConflictStarts` counts conflicts). Lines end at line
// feeds; a carriage return before one belongs to the line ending.
//
// Reported markers that make no whole conflict (an opening marker with no
// closing one, a closing marker before the separator) are stray: their
// lines stay with the lines around them. Inside their side, `|||||||` and
// `=======` lines are their side's text (git reports marker-like lines
// that side added).

import Foundation

/// A conflicted file's text as its conflict markers divide it.
public struct ConflictedFileText: Sendable, Equatable {
    /// A run of whole lines.
    public struct Lines: Sendable, Equatable {
        /// The lines' bytes in the file, line endings included.
        public let range: Range<Int>
        /// The first line's number in the file, from 1.
        public let firstLine: Int
        /// How many lines.
        public let count: Int

        public init(range: Range<Int>, firstLine: Int, count: Int) {
            self.range = range
            self.firstLine = firstLine
            self.count = count
        }
    }

    /// A conflict: from the line that opens it to the line that closes it.
    public struct Conflict: Sendable, Equatable {
        /// Its bytes in the file, from the start of the opening marker's
        /// line through the end of the closing marker's, that line's ending
        /// included.
        public let range: Range<Int>
        /// Our side, between `<<<<<<<` and `|||||||` or `=======`.
        public let ours: Lines
        /// The common ancestor's lines, between `|||||||` and `=======`
        /// (the diff3 and zdiff3 styles); nil without them.
        public let base: Lines?
        /// Their side, between `=======` and `>>>>>>>`.
        public let theirs: Lines
    }

    /// A part of the file, in order.
    public enum Segment: Sendable, Equatable {
        /// Lines outside conflicts (stray markers included).
        case lines(Lines)
        case conflict(Conflict)
    }

    /// The file's bytes, as divided.
    public let data: Data
    /// The file, part by part.
    public let segments: [Segment]
    /// The numbers (from 1) of the markers git reported that make no whole
    /// conflict.
    public let strayMarkerLines: Set<Int>

    /// Divides `data` at the markers on `markerLines` (line numbers from 1,
    /// as `getConflictMarkerLines(_:path:)` reports them).
    public init(_ data: Data, markerLines: [Int]) {
        let bytes = [UInt8](data)
        self.data = Data(bytes)

        // Where each line starts.
        var starts: [Int] = []
        var offset = 0
        while offset < bytes.count {
            starts.append(offset)
            offset = bytes[offset...].firstIndex(of: Self.lineFeed).map { $0 + 1 } ?? bytes.count
        }
        let lineCount = starts.count
        func start(ofLine index: Int) -> Int {
            index < lineCount ? starts[index] : bytes.count
        }
        /// Lines `from` up to `to` (indexes from 0).
        func lines(_ from: Int, _ to: Int) -> Lines {
            Lines(range: start(ofLine: from)..<start(ofLine: to), firstLine: from + 1, count: to - from)
        }

        /// A conflict opened but not yet closed.
        struct Open {
            enum Section {
                case ours, base, theirs
            }

            /// The opening marker's line index.
            let start: Int
            var section = Section.ours
            /// The `|||||||` line's index, if any.
            var base: Int?
            /// The `=======` line's index, once seen.
            var separator: Int?
            /// Its markers' line numbers.
            var markers: [Int]
        }

        let markers = Set(markerLines)
        var segments: [Segment] = []
        var stray = Set<Int>()
        // Where the run of lines outside conflicts started.
        var plainStart = 0
        var open: Open?

        for index in 0..<lineCount {
            let number = index + 1
            guard markers.contains(number), starts[index] < bytes.count else {
                continue
            }
            switch bytes[starts[index]] {
            case UInt8(ascii: "<"):
                // Another opening marker: the open one wasn't a conflict.
                if let open {
                    stray.formUnion(open.markers)
                }
                open = Open(start: index, markers: [number])
            case UInt8(ascii: "|"):
                if var current = open {
                    if current.section == .ours {
                        current.section = .base
                        current.base = index
                        current.markers.append(number)
                        open = current
                    }
                } else {
                    stray.insert(number)
                }
            case UInt8(ascii: "="):
                if var current = open {
                    if current.section != .theirs {
                        current.section = .theirs
                        current.separator = index
                        current.markers.append(number)
                        open = current
                    }
                } else {
                    stray.insert(number)
                }
            case UInt8(ascii: ">"):
                guard let current = open else {
                    stray.insert(number)
                    continue
                }
                open = nil
                guard current.section == .theirs, let separator = current.separator else {
                    // Closed before its separator: not a conflict.
                    stray.formUnion(current.markers)
                    stray.insert(number)
                    continue
                }
                if plainStart < current.start {
                    segments.append(.lines(lines(plainStart, current.start)))
                }
                segments.append(.conflict(Conflict(
                    range: start(ofLine: current.start)..<start(ofLine: index + 1),
                    ours: lines(current.start + 1, current.base ?? separator),
                    base: current.base.map { lines($0 + 1, separator) },
                    theirs: lines(separator + 1, index)
                )))
                plainStart = index + 1
            default:
                continue
            }
        }
        // Opened and never closed: not a conflict.
        if let open {
            stray.formUnion(open.markers)
        }
        if plainStart < lineCount {
            segments.append(.lines(lines(plainStart, lineCount)))
        }
        self.segments = segments
        strayMarkerLines = stray
    }

    /// The conflicts, in order.
    public var conflicts: [Conflict] {
        segments.compactMap { segment in
            if case .conflict(let conflict) = segment {
                return conflict
            }
            return nil
        }
    }

    /// Whether the file's last line has no line ending.
    public var lacksFinalNewline: Bool {
        data.last.map { $0 != Self.lineFeed } ?? false
    }

    /// The text of each of `lines`, without its line ending, decoded as
    /// UTF-8 (bytes that aren't are replaced).
    public func text(of lines: Lines) -> [String] {
        guard !lines.range.isEmpty else {
            return []
        }
        var texts: [String] = []
        texts.reserveCapacity(lines.count)
        var lineStart = lines.range.lowerBound
        while lineStart < lines.range.upperBound {
            let end = data[lineStart..<lines.range.upperBound].firstIndex(of: Self.lineFeed) ?? lines.range.upperBound
            var contentEnd = end
            if end < lines.range.upperBound, contentEnd > lineStart, data[contentEnd - 1] == Self.carriageReturn {
                contentEnd -= 1
            }
            texts.append(String(decoding: data[lineStart..<contentEnd], as: UTF8.self))
            lineStart = end + 1
        }
        return texts
    }

    /// The file with conflict `index` (in `conflicts`) replaced by `side`'s
    /// lines; everything else, line endings included, stays as it is. A
    /// conflict that ends the file without a line ending leaves the kept
    /// lines without their last one's. Nil when there's no such conflict.
    public func resolving(_ index: Int, with side: ManualConflictResolution) -> Data? {
        let conflicts = conflicts
        guard conflicts.indices.contains(index) else {
            return nil
        }
        let conflict = conflicts[index]
        var kept = (side == .ours ? conflict.ours : conflict.theirs).range
        if conflict.range.upperBound == data.count, lacksFinalNewline, !kept.isEmpty, data[kept.upperBound - 1] == Self.lineFeed {
            var end = kept.upperBound - 1
            if end > kept.lowerBound, data[end - 1] == Self.carriageReturn {
                end -= 1
            }
            kept = kept.lowerBound..<end
        }
        var resolved = Data()
        resolved.reserveCapacity(data.count - conflict.range.count + kept.count)
        resolved.append(data[0..<conflict.range.lowerBound])
        resolved.append(data[kept])
        resolved.append(data[conflict.range.upperBound..<data.count])
        return resolved
    }

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
}

// Ported from desktop/app/src/lib/status-parser.ts
//
// This parses the bytes directly rather than matching each entry with the
// regular expressions below: every field before the path is a fixed pattern
// followed by one space, so each expression has exactly one way to match,
// and checking the fields in order accepts and rejects exactly the lines the
// expressions do. Strings are decoded per field, which gives the same text
// as decoding the whole output (a NUL or ASCII space always starts a new
// character in UTF-8).

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "status")

/// A header line from `git status --branch --porcelain=2`, such as
/// `branch.head main`, without its `# ` prefix.
public struct StatusHeader: Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// A representation of a parsed status entry from git status
public struct StatusEntry: Hashable, Sendable {
    /// The path to the file relative to the repository root
    public let path: String

    /// The two character long status code
    public let statusCode: String

    /// The four character long submodule status code
    public let submoduleStatusCode: String

    /// The original path in the case of a renamed file
    public let oldPath: String?

    /// The rename or copy score in the case of a renamed file
    public let renameOrCopyScore: Int?

    public init(
        path: String,
        statusCode: String,
        submoduleStatusCode: String,
        oldPath: String? = nil,
        renameOrCopyScore: Int? = nil
    ) {
        self.path = path
        self.statusCode = statusCode
        self.submoduleStatusCode = submoduleStatusCode
        self.oldPath = oldPath
        self.renameOrCopyScore = renameOrCopyScore
    }
}

/// A parsed item of `git status` output: a header or an entry.
public enum StatusItem: Hashable, Sendable {
    case header(StatusHeader)
    case entry(StatusEntry)

    /// The header, if this is one.
    public var header: StatusHeader? {
        if case .header(let header) = self {
            return header
        }
        return nil
    }

    /// The entry, if this is one.
    public var entry: StatusEntry? {
        if case .entry(let entry) = self {
            return entry
        }
        return nil
    }
}

public func isStatusHeader(_ statusItem: StatusItem) -> Bool {
    statusItem.header != nil
}

public func isStatusEntry(_ statusItem: StatusItem) -> Bool {
    statusItem.entry != nil
}

private let ChangedEntryType = UInt8(ascii: "1")
private let RenamedOrCopiedEntryType = UInt8(ascii: "2")
private let UnmergedEntryType = UInt8(ascii: "u")
private let UntrackedEntryType = UInt8(ascii: "?")
private let IgnoredEntryType = UInt8(ascii: "!")

/// Parses output from git status --porcelain -z into file status entries
///
/// - Throws: `GitLibError` when an entry doesn't have the expected format.
public func parsePorcelainStatus(_ output: Data) throws -> [StatusItem] {
    try output.withUnsafeBytes { raw in
        try parsePorcelainStatus(raw.bindMemory(to: UInt8.self))
    }
}

private func parsePorcelainStatus(_ bytes: UnsafeBufferPointer<UInt8>) throws -> [StatusItem] {
    var entries: [StatusItem] = []

    // See https://git-scm.com/docs/git-status
    //
    // In the short-format, the status of each path is shown as
    // XY PATH1 -> PATH2
    //
    // There is also an alternate -z format recommended for machine parsing. In that
    // format, the status field is the same, but some other things change. First,
    // the -> is omitted from rename entries and the field order is reversed (e.g
    // from -> to becomes to from). Second, a NUL (ASCII 0) follows each filename,
    // replacing space as a field separator and the terminating newline (but a space
    // still separates the status field from the first filename). Third, filenames
    // containing special characters are not specially formatted; no quoting or
    // backslash-escaping is performed.

    let tokens = splitOnNUL(bytes)

    var i = 0
    while i < tokens.count {
        defer { i += 1 }
        let field = Field(bytes: bytes, range: tokens[i])

        if field.count > 2, field[0] == UInt8(ascii: "#"), field[1] == UInt8(ascii: " ") {
            entries.append(.header(StatusHeader(value: field.string(from: 2))))
            continue
        }

        guard field.count > 0 else {
            continue
        }

        switch field[0] {
        case ChangedEntryType:
            entries.append(.entry(try parseChangedEntry(field)))
        case RenamedOrCopiedEntryType:
            i += 1
            let oldPath = i < tokens.count ? Field(bytes: bytes, range: tokens[i]).string(from: 0) : nil
            entries.append(.entry(try parsedRenamedOrCopiedEntry(field, oldPath)))
        case UnmergedEntryType:
            entries.append(.entry(try parseUnmergedEntry(field)))
        case UntrackedEntryType:
            entries.append(.entry(parseUntrackedEntry(field)))
        case IgnoredEntryType:
            // Ignored, we don't care about these for now
            break
        default:
            break
        }
    }

    return entries
}

// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
//
// /^1 ([MADRCUTX?!.]{2}) (N\.\.\.|S[C.][M.][U.]) (\d+) (\d+) (\d+) ([a-f0-9]+) ([a-f0-9]+) ([\s\S]*?)$/
private func parseChangedEntry(_ field: Field) throws -> StatusEntry {
    var scanner = FieldScanner(field: field)
    guard scanner.expect("1"), scanner.expect(" "),
          let statusCode = scanner.statusCode(), scanner.expect(" "),
          let submoduleStatusCode = scanner.submoduleStatusCode(), scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" ")
    else {
        logger.debug("parseChangedEntry parse error: \(field.string(from: 0), privacy: .private)")
        throw GitLibError("Failed to parse status line for changed entry")
    }

    return StatusEntry(
        path: field.string(scanner.remainder),
        statusCode: field.string(statusCode),
        submoduleStatusCode: field.string(submoduleStatusCode)
    )
}

// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
//
// /^2 ([MADRCUTX?!.]{2}) (N\.\.\.|S[C.][M.][U.]) (\d+) (\d+) (\d+) ([a-f0-9]+) ([a-f0-9]+) ([RC]\d+) ([\s\S]*?)$/
private func parsedRenamedOrCopiedEntry(_ field: Field, _ oldPath: String?) throws -> StatusEntry {
    var scanner = FieldScanner(field: field)
    guard scanner.expect("2"), scanner.expect(" "),
          let statusCode = scanner.statusCode(), scanner.expect(" "),
          let submoduleStatusCode = scanner.submoduleStatusCode(), scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" "),
          let score = scanner.score(), scanner.expect(" ")
    else {
        logger.debug("parsedRenamedOrCopiedEntry parse error: \(field.string(from: 0), privacy: .private)")
        throw GitLibError("Failed to parse status line for renamed or copied entry")
    }

    guard let oldPath, !oldPath.isEmpty else {
        throw GitLibError("Failed to parse renamed or copied entry, could not parse old path")
    }

    return StatusEntry(
        path: field.string(scanner.remainder),
        statusCode: field.string(statusCode),
        submoduleStatusCode: field.string(submoduleStatusCode),
        oldPath: oldPath,
        renameOrCopyScore: field.integer(score.dropFirst())
    )
}

// u <xy> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
//
// /^u ([DAU]{2}) (N\.\.\.|S[C.][M.][U.]) (\d+) (\d+) (\d+) (\d+) ([a-f0-9]+) ([a-f0-9]+) ([a-f0-9]+) ([\s\S]*?)$/
private func parseUnmergedEntry(_ field: Field) throws -> StatusEntry {
    var scanner = FieldScanner(field: field)
    guard scanner.expect("u"), scanner.expect(" "),
          let statusCode = scanner.unmergedStatusCode(), scanner.expect(" "),
          let submoduleStatusCode = scanner.submoduleStatusCode(), scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.digits() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" "),
          scanner.hex() != nil, scanner.expect(" ")
    else {
        logger.debug("parseUnmergedEntry parse error: \(field.string(from: 0), privacy: .private)")
        throw GitLibError("Failed to parse status line for unmerged entry")
    }

    return StatusEntry(
        path: field.string(scanner.remainder),
        statusCode: field.string(statusCode),
        submoduleStatusCode: field.string(submoduleStatusCode)
    )
}

private func parseUntrackedEntry(_ field: Field) -> StatusEntry {
    // Git writes `? <path>`, so the path starts after the two ASCII bytes.
    let path = field.string(from: min(2, field.count))
    return StatusEntry(
        path: path,
        // NOTE: We return ?? instead of ? here to play nice with mapStatus.
        statusCode: "??",
        submoduleStatusCode: "????"
    )
}

private func mapSubmoduleStatus(_ submoduleStatusCode: String) -> SubmoduleStatus? {
    // The code is read as UTF-16 code units; a missing one matches nothing.
    var code = submoduleStatusCode.utf16.makeIterator()
    guard code.next() == UInt16(UInt8(ascii: "S")) else {
        return nil
    }

    return SubmoduleStatus(
        commitChanged: code.next() == UInt16(UInt8(ascii: "C")),
        modifiedChanges: code.next() == UInt16(UInt8(ascii: "M")),
        untrackedChanges: code.next() == UInt16(UInt8(ascii: "U"))
    )
}

/// Map the raw status text from Git to a structure we can work with in the app.
public func mapStatus(
    _ statusCode: String,
    _ submoduleStatusCode: String,
    _ renameOrCopyScore: Int?
) -> FileEntry {
    let submoduleStatus = mapSubmoduleStatus(submoduleStatusCode)

    // These codes are ASCII, so Swift's `==` compares them exactly.
    switch statusCode {
    case "??":
        return .untracked(UntrackedEntry(submoduleStatus: submoduleStatus))
    case ".M":
        return .ordinary(OrdinaryEntry(type: .modified, index: .unchanged, workingTree: .modified, submoduleStatus: submoduleStatus))
    case "M.":
        return .ordinary(OrdinaryEntry(type: .modified, index: .modified, workingTree: .unchanged, submoduleStatus: submoduleStatus))
    case ".A":
        return .ordinary(OrdinaryEntry(type: .added, index: .unchanged, workingTree: .added, submoduleStatus: submoduleStatus))
    case "A.":
        return .ordinary(OrdinaryEntry(type: .added, index: .added, workingTree: .unchanged, submoduleStatus: submoduleStatus))
    case ".D":
        return .ordinary(OrdinaryEntry(type: .deleted, index: .unchanged, workingTree: .deleted, submoduleStatus: submoduleStatus))
    case "D.":
        return .ordinary(OrdinaryEntry(type: .deleted, index: .deleted, workingTree: .unchanged, submoduleStatus: submoduleStatus))
    case "R.":
        return .renamed(RenamedOrCopiedEntry(
            index: .renamed,
            workingTree: .unchanged,
            submoduleStatus: submoduleStatus,
            renameOrCopyScore: renameOrCopyScore
        ))
    case ".R":
        return .renamed(RenamedOrCopiedEntry(
            index: .unchanged,
            workingTree: .renamed,
            submoduleStatus: submoduleStatus,
            renameOrCopyScore: renameOrCopyScore
        ))
    case "C.":
        return .copied(RenamedOrCopiedEntry(index: .copied, workingTree: .unchanged, submoduleStatus: submoduleStatus))
    case ".C":
        return .copied(RenamedOrCopiedEntry(index: .unchanged, workingTree: .copied, submoduleStatus: submoduleStatus))
    case "AD":
        return .ordinary(OrdinaryEntry(type: .added, index: .added, workingTree: .deleted, submoduleStatus: submoduleStatus))
    case "AM":
        return .ordinary(OrdinaryEntry(type: .added, index: .added, workingTree: .modified, submoduleStatus: submoduleStatus))
    case "RM":
        return .renamed(RenamedOrCopiedEntry(
            index: .renamed,
            workingTree: .modified,
            submoduleStatus: submoduleStatus,
            renameOrCopyScore: renameOrCopyScore
        ))
    case "RD":
        return .renamed(RenamedOrCopiedEntry(
            index: .renamed,
            workingTree: .deleted,
            submoduleStatus: submoduleStatus,
            renameOrCopyScore: renameOrCopyScore
        ))
    case "DD":
        return .conflicted(UnmergedEntry(action: .bothDeleted, submoduleStatus: submoduleStatus))
    case "AU":
        return .conflicted(UnmergedEntry(action: .addedByUs, submoduleStatus: submoduleStatus))
    case "UD":
        return .conflicted(UnmergedEntry(action: .deletedByThem, submoduleStatus: submoduleStatus))
    case "UA":
        return .conflicted(UnmergedEntry(action: .addedByThem, submoduleStatus: submoduleStatus))
    case "DU":
        return .conflicted(UnmergedEntry(action: .deletedByUs, submoduleStatus: submoduleStatus))
    case "AA":
        return .conflicted(UnmergedEntry(action: .bothAdded, submoduleStatus: submoduleStatus))
    case "UU":
        return .conflicted(UnmergedEntry(action: .bothModified, submoduleStatus: submoduleStatus))
    default:
        // as a fallback, we assume the file is modified in some way
        return .ordinary(OrdinaryEntry(type: .modified, submoduleStatus: submoduleStatus))
    }
}

// MARK: - Byte scanning

/// The ranges between NUL bytes, including empty ones and the trailing one,
/// as `splitBuffer(output, "\0")` returns them.
private func splitOnNUL(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
    guard let base = bytes.baseAddress else {
        return [0..<0]
    }
    var ranges: [Range<Int>] = []
    var start = 0
    while start < bytes.count,
          let found = memchr(base + start, 0, bytes.count - start) {
        let end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        ranges.append(start..<end)
        start = end + 1
    }
    ranges.append(start..<bytes.count)
    return ranges
}

/// One NUL-separated field of the output.
private struct Field {
    let bytes: UnsafeBufferPointer<UInt8>
    let range: Range<Int>

    var count: Int { range.count }

    subscript(offset: Int) -> UInt8 {
        bytes[range.lowerBound + offset]
    }

    /// The field's text from `offset` (relative to the field) to its end,
    /// decoded as UTF-8 with replacement characters.
    func string(from offset: Int) -> String {
        string((range.lowerBound + offset)..<range.upperBound)
    }

    /// The text of an absolute byte range of the output.
    func string(_ absolute: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[absolute]), as: UTF8.self)
    }

    /// The value of the ASCII digits in an absolute byte range, or nil when
    /// it doesn't fit in an `Int`.
    func integer(_ absolute: Range<Int>) -> Int? {
        var value = 0
        for index in absolute {
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: 10)
            let (added, overflowAdd) = multiplied.addingReportingOverflow(Int(bytes[index] - UInt8(ascii: "0")))
            if overflow || overflowAdd {
                return nil
            }
            value = added
        }
        return value
    }
}

/// Matches the fixed-format fields of a status entry in order. Each method
/// consumes its field and returns its absolute range, or nil without
/// consuming anything when the field doesn't match.
private struct FieldScanner {
    let field: Field
    /// The absolute position of the next byte to match.
    private(set) var position: Int

    init(field: Field) {
        self.field = field
        self.position = field.range.lowerBound
    }

    private var end: Int { field.range.upperBound }

    /// The absolute range of the rest of the field: `([\s\S]*?)$`.
    var remainder: Range<Int> { position..<end }

    private func byte(at index: Int) -> UInt8? {
        index < end ? field.bytes[index] : nil
    }

    mutating func expect(_ character: Unicode.Scalar) -> Bool {
        guard byte(at: position) == UInt8(ascii: character) else {
            return false
        }
        position += 1
        return true
    }

    /// `[MADRCUTX?!.]{2}`
    mutating func statusCode() -> Range<Int>? {
        fixed(2) { "MADRCUTX?!.".utf8.contains($0) }
    }

    /// `[DAU]{2}`
    mutating func unmergedStatusCode() -> Range<Int>? {
        fixed(2) { "DAU".utf8.contains($0) }
    }

    /// `N\.\.\.|S[C.][M.][U.]`
    mutating func submoduleStatusCode() -> Range<Int>? {
        let start = position
        let dot = UInt8(ascii: ".")
        let code = (0..<4).map { byte(at: start + $0) }
        let matches: Bool
        switch code[0] {
        case UInt8(ascii: "N"):
            matches = code[1] == dot && code[2] == dot && code[3] == dot
        case UInt8(ascii: "S"):
            matches = (code[1] == UInt8(ascii: "C") || code[1] == dot)
                && (code[2] == UInt8(ascii: "M") || code[2] == dot)
                && (code[3] == UInt8(ascii: "U") || code[3] == dot)
        default:
            matches = false
        }
        guard matches else {
            return nil
        }
        position += 4
        return start..<position
    }

    /// `\d+` (ASCII digits, as in JavaScript)
    mutating func digits() -> Range<Int>? {
        run { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// `[a-f0-9]+`
    mutating func hex() -> Range<Int>? {
        run { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// `[RC]\d+`
    mutating func score() -> Range<Int>? {
        let start = position
        guard let first = byte(at: start), first == UInt8(ascii: "R") || first == UInt8(ascii: "C") else {
            return nil
        }
        position += 1
        guard digits() != nil else {
            position = start
            return nil
        }
        return start..<position
    }

    private mutating func fixed(_ count: Int, _ allowed: (UInt8) -> Bool) -> Range<Int>? {
        let start = position
        for offset in 0..<count {
            guard let byte = byte(at: start + offset), allowed(byte) else {
                return nil
            }
        }
        position += count
        return start..<position
    }

    private mutating func run(_ allowed: (UInt8) -> Bool) -> Range<Int>? {
        let start = position
        var index = start
        while let byte = byte(at: index), allowed(byte) {
            index += 1
        }
        guard index > start else {
            return nil
        }
        position = index
        return start..<index
    }
}

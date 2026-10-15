// Carrying a selection of a diff's lines over to another diff of the same
// file, after the file changed: by the lines themselves, not their
// positions.

import EspalierSupport

extension DiffSelection {
    /// This selection, made of the lines of `diffHunks`, as a selection of
    /// the lines of `hunks`, another diff of the same file, whose selectable
    /// lines are `selectableLines`.
    ///
    /// - When `diffHunks` has the same lines as `hunks`, the selection
    ///   stays as it is.
    /// - Otherwise a whole-file choice stays one: every line, or none.
    /// - Without `diffHunks`, the indexes are taken to name `hunks`' lines.
    /// - Otherwise each changed line keeps its choice when it's found again:
    ///   a deleted line by its number and text in the old file (the diffs'
    ///   common base); an added line by its text, where it can be told
    ///   apart from identical lines (`matchLines`). A line that can't be
    ///   found, or told apart, is left out.
    ///
    /// The result's `diffHunks` are `hunks` (or, when `diffHunks` has the
    /// same lines, `diffHunks`).
    public func carried(to hunks: [DiffHunk], selectableLines: Set<Int>) -> DiffSelection {
        if let base = diffHunks, hasSameHunkLines(base, hunks) {
            return withSelectableLines(selectableLines)
        }
        let type = getSelectionType()
        guard type == .partial else {
            return DiffSelection.fromInitialSelection(type).withSelectableLines(selectableLines)
        }
        guard let base = diffHunks else {
            return withSelectableLines(selectableLines).withDiffHunks(hunks)
        }

        var selected = Set<Int>()

        // A deleted line is a line of the old file, the same in both diffs.
        var deletions: [DeletedLineKey: Bool] = [:]
        forEachLine(of: base) { index, line in
            if line.type == .delete {
                deletions[DeletedLineKey(line)] = isSelected(index)
            }
        }
        forEachLine(of: hunks) { index, line in
            if line.type == .delete, deletions[DeletedLineKey(line)] == true {
                selected.insert(index)
            }
        }

        // An added line is found among the lines of the new file the diffs
        // show (context and added lines).
        var ids: [NewSideLineKey: Int] = [:]
        let from = NewSideLines(base, ids: &ids)
        let to = NewSideLines(hunks, ids: &ids)
        for (i, j) in matchLines(from.ids, to.ids) where from.isAdded[i] && isSelected(from.indexes[i]) {
            selected.insert(to.indexes[j])
        }

        return DiffSelection.selecting(selected.intersection(selectableLines), of: selectableLines, in: hunks)
    }
}

/// The indexes of the added and deleted lines of `hunks`
/// (`hunk.unifiedDiffStart` plus the line's index in its hunk).
public func includeableLineIndexes(_ hunks: [DiffHunk]) -> Set<Int> {
    var indexes = Set<Int>()
    forEachLine(of: hunks) { index, line in
        if line.isIncludeableLine() {
            indexes.insert(index)
        }
    }
    return indexes
}

/// Calls `body` with each line of `hunks` and its index in the diff.
private func forEachLine(of hunks: [DiffHunk], _ body: (Int, DiffLine) -> Void) {
    for hunk in hunks {
        for (offset, line) in hunk.lines.enumerated() {
            body(hunk.unifiedDiffStart + offset, line)
        }
    }
}

/// Whether two diffs' hunks have the same lines, byte for byte, at the same
/// indexes.
private func hasSameHunkLines(_ x: [DiffHunk], _ y: [DiffHunk]) -> Bool {
    guard x.count == y.count else {
        return false
    }
    let sameStorage = x.withUnsafeBufferPointer { xs in
        y.withUnsafeBufferPointer { ys in xs.baseAddress == ys.baseAddress }
    }
    if sameStorage {
        return true
    }
    for (a, b) in zip(x, y) {
        guard a.header == b.header, a.unifiedDiffStart == b.unifiedDiffStart, a.lines.count == b.lines.count else {
            return false
        }
        for (l, r) in zip(a.lines, b.lines) {
            guard l.type == r.type, l.noTrailingNewLine == r.noTrailingNewLine, ExactString(l.text) == ExactString(r.text) else {
                return false
            }
        }
    }
    return true
}

/// A deleted line: its number and text in the old file.
private struct DeletedLineKey: Hashable {
    let number: Int?
    let text: ExactString
    let noTrailingNewLine: Bool

    init(_ line: DiffLine) {
        number = line.oldLineNumber
        text = ExactString(line.text)
        noTrailingNewLine = line.noTrailingNewLine
    }
}

/// A line of the new file as a diff shows it: a context line is the old
/// file's line with that number and text; an added line is its text.
private enum NewSideLineKey: Hashable {
    case context(number: Int?, text: ExactString, noTrailingNewLine: Bool)
    case added(text: ExactString, noTrailingNewLine: Bool)
}

/// A diff's context and added lines, in order: each as a number standing
/// for its `NewSideLineKey` (the same number for the same key), whether
/// it's added, and its index in the diff.
private struct NewSideLines {
    var ids: [Int] = []
    var isAdded: [Bool] = []
    var indexes: [Int] = []

    init(_ hunks: [DiffHunk], ids keyIDs: inout [NewSideLineKey: Int]) {
        forEachLine(of: hunks) { index, line in
            let key: NewSideLineKey
            switch line.type {
            case .context:
                key = .context(number: line.oldLineNumber, text: ExactString(line.text), noTrailingNewLine: line.noTrailingNewLine)
            case .add:
                key = .added(text: ExactString(line.text), noTrailingNewLine: line.noTrailingNewLine)
            case .delete, .hunk:
                return
            }
            let id = keyIDs[key] ?? keyIDs.count
            keyIDs[key] = id
            ids.append(id)
            isAdded.append(line.type == .add)
            indexes.append(index)
        }
    }
}

/// The largest grid `forcedMatches` works through (the product of the two
/// runs' lengths); a longer pair of runs is left unmatched.
let forcedMatchLimit = 1_000_000

/// The lines of `a` and `b` (sequences of line IDs, equal for equal lines)
/// that are the same line, as pairs of positions.
///
/// A line that occurs once in each is the same line, wherever it moved.
/// Those that keep their order split the sequences into runs between
/// them, which are matched the same way, a line now counting as unique
/// when it's unique within its run. Two runs that are the same lines are
/// matched line by line. Otherwise a line is matched only when every
/// longest common subsequence of the two runs pairs it with the same line
/// (`forcedMatches`): identical lines that could be any of several are left
/// unmatched.
func matchLines(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    var matches: [(Int, Int)] = []
    var runs: [(a: [Int], b: [Int])] = [(Array(a.indices), Array(b.indices))]
    while let (aRun, bRun) = runs.popLast() {
        guard !aRun.isEmpty, !bRun.isEmpty else {
            continue
        }
        if aRun.count == bRun.count, zip(aRun, bRun).allSatisfy({ a[$0] == b[$1] }) {
            matches.append(contentsOf: zip(aRun, bRun))
            continue
        }

        // Lines that occur once in each run.
        var occurrences: [Int: (aCount: Int, aPosition: Int, bCount: Int, bPosition: Int)] = [:]
        for position in aRun {
            occurrences[a[position], default: (0, 0, 0, 0)].aCount += 1
            occurrences[a[position]]!.aPosition = position
        }
        for position in bRun where occurrences[b[position]] != nil {
            occurrences[b[position]]!.bCount += 1
            occurrences[b[position]]!.bPosition = position
        }
        let unique = occurrences.values
            .filter { $0.aCount == 1 && $0.bCount == 1 }
            .map { ($0.aPosition, $0.bPosition) }
            .sorted { $0.0 < $1.0 }
        guard !unique.isEmpty else {
            matches.append(contentsOf: forcedMatches(aRun, bRun, a, b))
            continue
        }
        matches.append(contentsOf: unique)

        // The runs between the unique lines that keep their order; the
        // others (moved) are matched and left out.
        let anchors = longestIncreasingRun(unique)
        let matchedA = Set(unique.map(\.0))
        let matchedB = Set(unique.map(\.1))
        var aStart = aRun.startIndex
        var bStart = bRun.startIndex
        for anchor in anchors + [(Int.max, Int.max)] {
            let aEnd = aRun[aStart...].firstIndex { $0 >= anchor.0 } ?? aRun.endIndex
            let bEnd = bRun[bStart...].firstIndex { $0 >= anchor.1 } ?? bRun.endIndex
            runs.append((
                aRun[aStart..<aEnd].filter { !matchedA.contains($0) },
                bRun[bStart..<bEnd].filter { !matchedB.contains($0) }
            ))
            aStart = min(aEnd + 1, aRun.endIndex)
            bStart = min(bEnd + 1, bRun.endIndex)
        }
    }
    return matches
}

/// The longest run of `pairs` (sorted by their first position) whose second
/// positions increase too.
private func longestIncreasingRun(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
    // tails[k]: the index in `pairs` of the smallest second position that
    // ends an increasing run of length k + 1.
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: pairs.count)
    for (index, pair) in pairs.enumerated() {
        var low = 0
        var high = tails.count
        while low < high {
            let middle = (low + high) / 2
            if pairs[tails[middle]].1 < pair.1 {
                low = middle + 1
            } else {
                high = middle
            }
        }
        previous[index] = low > 0 ? tails[low - 1] : -1
        if low == tails.count {
            tails.append(index)
        } else {
            tails[low] = index
        }
    }
    var run: [(Int, Int)] = []
    var index = tails.last ?? -1
    while index >= 0 {
        run.append(pairs[index])
        index = previous[index]
    }
    return run.reversed()
}

/// The pairs of positions in `aRun` and `bRun` that every longest common
/// subsequence of the two runs' lines contains; none when the runs are too
/// long to compare (`forcedMatchLimit`).
private func forcedMatches(_ aRun: [Int], _ bRun: [Int], _ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    let n = aRun.count
    let m = bRun.count
    guard n * m <= forcedMatchLimit else {
        return []
    }
    let x = aRun.map { a[$0] }
    let y = bRun.map { b[$0] }
    let width = m + 1
    // prefix[i * width + j]: the longest common subsequence of x[..<i] and
    // y[..<j]; suffix[i * width + j]: of x[i...] and y[j...].
    var prefix = [Int32](repeating: 0, count: (n + 1) * width)
    var suffix = [Int32](repeating: 0, count: (n + 1) * width)
    for i in 1...n {
        for j in 1...m {
            prefix[i * width + j] = x[i - 1] == y[j - 1]
                ? prefix[(i - 1) * width + j - 1] + 1
                : max(prefix[(i - 1) * width + j], prefix[i * width + j - 1])
        }
    }
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            suffix[i * width + j] = x[i] == y[j]
                ? suffix[(i + 1) * width + j + 1] + 1
                : max(suffix[(i + 1) * width + j], suffix[i * width + j + 1])
        }
    }
    let longest = prefix[n * width + m]
    var matches: [(Int, Int)] = []
    for i in 0..<n {
        // Some longest subsequence leaves x[i] out.
        if (0...m).contains(where: { prefix[i * width + $0] + suffix[(i + 1) * width + $0] == longest }) {
            continue
        }
        // The y lines x[i] is paired with in some longest subsequence.
        let partners = (0..<m).filter { j in
            x[i] == y[j] && prefix[i * width + j] + 1 + suffix[(i + 1) * width + j + 1] == longest
        }
        if partners.count == 1 {
            matches.append((aRun[i], bRun[partners[0]]))
        }
    }
    return matches
}

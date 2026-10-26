// The command palette's matching: fuzzy, case-insensitive, and ranked. A
// query's characters match a text's in order, Unicode scalar by scalar,
// each lowercased. A match's kind ranks it, best first: the whole text, a
// prefix of it, the start of one of its words ("branch" in "New Branch…"),
// the starts of several words ("sb" in "Switch Branch…"), anywhere in it,
// then scattered through it. Within a kind, a match nearer the start of a
// shorter text ranks higher; a scattered match is scored by its best
// alignment, which favors runs and word starts and costs gaps.
//
// A query of several words matches as a whole when it's contiguous in the
// text; otherwise each word matches on its own, in any order, in the text
// or else in the item's context (an action's menu), and the match ranks
// as its worst word's. The texts are prepared once and the query once per
// keystroke, and a mask of the scalars each text has turns most texts away
// before any matching, so a few thousand branches match in milliseconds.

/// A text prepared for matching: its scalars lowercased one by one, and
/// which of them start a word.
nonisolated struct PaletteSearchText: Sendable {
    /// The text as shown.
    let text: String
    fileprivate let units: [UInt32]
    fileprivate let wordStarts: [Bool]
    /// Which scalars the text has (`PaletteSearchText.bit(_:)`), to turn a
    /// query away at once when it has others.
    fileprivate let mask: UInt64

    init(_ text: String) {
        self.text = text
        var units: [UInt32] = []
        var wordStarts: [Bool] = []
        var mask: UInt64 = 0
        units.reserveCapacity(text.utf8.count)
        wordStarts.reserveCapacity(text.utf8.count)
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            let unit = PaletteSearchText.folded(scalar)
            units.append(unit)
            mask |= PaletteSearchText.bit(unit)
            wordStarts.append(PaletteSearchText.startsWord(scalar, after: previous))
            previous = scalar
        }
        self.units = units
        self.wordStarts = wordStarts
        self.mask = mask
    }

    /// A scalar's bit in a mask of the scalars a text has: scalars that
    /// share one tell nothing apart, but a scalar whose bit a text lacks
    /// isn't in it.
    fileprivate static func bit(_ unit: UInt32) -> UInt64 {
        1 << UInt64(unit & 63)
    }

    /// The scalar lowercased: its lowercase mapping's first scalar, so each
    /// scalar of the text stays one.
    fileprivate static func folded(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0x80 {
            return (0x41...0x5A).contains(value) ? value + 0x20 : value
        }
        return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? value
    }

    /// Whether `scalar` starts a word: a letter or digit first in the text
    /// or after anything else ("login" in "feature/login"), an uppercase
    /// letter after a lowercase one ("Kit" in "GitKit"), or a digit after
    /// a letter ("2" in "v2").
    private static func startsWord(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        guard isAlphanumeric(scalar) else {
            return false
        }
        guard let previous, isAlphanumeric(previous) else {
            return true
        }
        let current = scalar.properties
        let before = previous.properties
        if before.isLowercase, current.isUppercase {
            return true
        }
        return before.isAlphabetic && current.numericType != nil
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}

/// How well a query matched a text.
nonisolated struct PaletteMatch: Sendable, Comparable {
    /// What kind of match it is, worst first.
    enum Kind: Int, Sendable, Comparable {
        /// Some words matched only the item's context.
        case context
        /// Scattered through the text.
        case scattered
        /// Contiguous, inside a word.
        case substring
        /// On the starts of several words.
        case wordStarts
        /// Contiguous, from the start of a word.
        case wordPrefix
        /// Contiguous, from the start of the text.
        case prefix
        /// The whole text.
        case exact

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let kind: Kind
    /// Ranks matches of one kind: higher is better.
    let score: Int
    /// The offsets of the text's scalars the query matched, in order.
    let positions: [Int]

    static func < (lhs: PaletteMatch, rhs: PaletteMatch) -> Bool {
        (lhs.kind, lhs.score) < (rhs.kind, rhs.score)
    }

    static func == (lhs: PaletteMatch, rhs: PaletteMatch) -> Bool {
        lhs.kind == rhs.kind && lhs.score == rhs.score
    }
}

/// A query prepared for matching many texts.
nonisolated struct PaletteQuery: Sendable {
    /// The query's words, lowercased, and their scalars' masks.
    private let words: [[UInt32]]
    private let wordMasks: [UInt64]
    /// The words joined by single spaces, and its scalars' mask.
    private let units: [UInt32]
    private let mask: UInt64

    /// Nil for a query of nothing but white space.
    init?(_ query: String) {
        let words = query.split(whereSeparator: \.isWhitespace).map { word in
            word.unicodeScalars.map(PaletteSearchText.folded)
        }
        guard !words.isEmpty else {
            return nil
        }
        self.words = words
        units = Array(words.joined(separator: [0x20]))
        wordMasks = words.map { $0.reduce(0) { $0 | PaletteSearchText.bit($1) } }
        mask = units.reduce(0) { $0 | PaletteSearchText.bit($1) }
    }

    /// How the query matches `text`, or nil when it doesn't. `context` is
    /// what else a word of a query of several may match (an action's
    /// menu), which ranks below any match in the text.
    func match(_ text: PaletteSearchText, context: PaletteSearchText? = nil) -> PaletteMatch? {
        guard words.count > 1 else {
            return Self.match(units, mask: mask, in: text, scatters: true)
        }
        let whole = Self.match(units, mask: mask, in: text, scatters: false)
        if let whole, whole.kind >= .wordPrefix {
            return whole
        }
        let byWord = matchWords(text, context: context)
        switch (whole, byWord) {
        case let (whole?, byWord?): return max(whole, byWord)
        case let (whole, byWord): return whole ?? byWord
        }
    }

    /// Each word matched on its own, in the text or else in `context`: as
    /// good as the worst word's match, scored by the sum.
    private func matchWords(_ text: PaletteSearchText, context: PaletteSearchText?) -> PaletteMatch? {
        var kind = PaletteMatch.Kind.exact
        var score = 0
        var positions = Set<Int>()
        for (word, mask) in zip(words, wordMasks) {
            if let match = Self.match(word, mask: mask, in: text, scatters: true) {
                kind = min(kind, match.kind)
                score += match.score
                positions.formUnion(match.positions)
            } else if let context, let match = Self.match(word, mask: mask, in: context, scatters: true) {
                kind = .context
                score += match.score
            } else {
                return nil
            }
        }
        return PaletteMatch(kind: kind, score: score, positions: positions.sorted())
    }

    // MARK: Matching one word

    /// How `query`, whose scalars' mask is `mask`, matches `text`:
    /// contiguously, or (when `scatters`) on word starts or scattered.
    private static func match(_ query: [UInt32], mask: UInt64, in text: PaletteSearchText, scatters: Bool) -> PaletteMatch? {
        let units = text.units
        let count = query.count
        guard count > 0, count <= units.count, mask & ~text.mask == 0 else {
            return nil
        }
        // The first contiguous occurrence, and the first at a word start.
        var firstStart: Int?
        var wordStart: Int?
        units.withUnsafeBufferPointer { units in
            query.withUnsafeBufferPointer { query in
                let first = query[0]
                var start = 0
                while start + count <= units.count {
                    if units[start] == first {
                        var length = 1
                        while length < count, units[start + length] == query[length] {
                            length += 1
                        }
                        if length == count {
                            if firstStart == nil {
                                firstStart = start
                            }
                            if start == 0 || text.wordStarts[start] {
                                wordStart = start
                                return
                            }
                        }
                    }
                    start += 1
                }
            }
        }
        let slack = units.count - count
        if let wordStart {
            let positions = Array(wordStart ..< wordStart + count)
            if wordStart == 0 {
                return PaletteMatch(kind: slack == 0 ? .exact : .prefix, score: -slack, positions: positions)
            }
            return PaletteMatch(kind: .wordPrefix, score: -wordStart * 4 - slack, positions: positions)
        }
        if scatters, let positions = wordStartPositions(query, in: text) {
            return PaletteMatch(kind: .wordStarts, score: -(positions.last ?? 0) * 4 - slack, positions: positions)
        }
        if let firstStart {
            return PaletteMatch(kind: .substring, score: -firstStart * 4 - slack, positions: Array(firstStart ..< firstStart + count))
        }
        return scatters ? scattered(query, in: text) : nil
    }

    /// Each of `query`'s scalars on the start of a word, in order, the
    /// earliest each time.
    private static func wordStartPositions(_ query: [UInt32], in text: PaletteSearchText) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var index = 0
        for unit in query {
            while index < text.units.count, !(text.wordStarts[index] && text.units[index] == unit) {
                index += 1
            }
            guard index < text.units.count else {
                return nil
            }
            positions.append(index)
            index += 1
        }
        return positions
    }

    // MARK: Scattered matches

    /// What a matched scalar scores, and what joins two.
    private enum Scoring {
        static let match = 16
        static let wordStart = 12
        static let firstScalar = 8
        static let consecutive = 14
        /// Each scalar skipped between two matched ones.
        static let gap = 3
        /// Each scalar before the first matched one, up to `leadLimit`.
        static let lead = 1
        static let leadLimit = 12
    }

    /// The best alignment of `query`'s scalars through `text`, in order:
    /// for each query scalar and each text scalar it could match, the best
    /// score of the alignments ending there. A gap's cost grows with its
    /// length, so the best earlier alignment to jump from is kept as the
    /// row is walked, and the whole takes the query's length times the
    /// text's.
    private static func scattered(_ query: [UInt32], in text: PaletteSearchText) -> PaletteMatch? {
        let units = text.units
        let width = units.count
        let height = query.count
        // A quick no: the scalars aren't in the text in order.
        var next = 0
        for unit in query {
            guard let found = units[next...].firstIndex(of: unit) else {
                return nil
            }
            next = found + 1
        }

        let none = Int.min / 4
        var scores = [Int](repeating: none, count: width * height)
        var from = [Int32](repeating: -1, count: width * height)
        for row in 0 ..< height {
            // The best alignment of the previous row ending at least two
            // scalars back, plus its gap's growth so far.
            var bestEarlier = none
            var bestEarlierColumn = -1
            for column in row ..< width {
                if row > 0, column >= 2 {
                    let earlier = column - 2
                    let score = scores[(row - 1) * width + earlier]
                    if score > none, score + Scoring.gap * earlier > bestEarlier {
                        bestEarlier = score + Scoring.gap * earlier
                        bestEarlierColumn = earlier
                    }
                }
                guard units[column] == query[row] else {
                    continue
                }
                var bonus = Scoring.match
                if text.wordStarts[column] {
                    bonus += Scoring.wordStart
                }
                if column == 0 {
                    bonus += Scoring.firstScalar
                }
                let cell = row * width + column
                if row == 0 {
                    scores[cell] = bonus - min(column, Scoring.leadLimit) * Scoring.lead
                    continue
                }
                var best = none
                var bestColumn = -1
                let adjacent = scores[(row - 1) * width + column - 1]
                if adjacent > none {
                    best = adjacent + Scoring.consecutive
                    bestColumn = column - 1
                }
                if bestEarlier > none, bestEarlier - Scoring.gap * (column - 1) > best {
                    best = bestEarlier - Scoring.gap * (column - 1)
                    bestColumn = bestEarlierColumn
                }
                if bestColumn >= 0 {
                    scores[cell] = best + bonus
                    from[cell] = Int32(bestColumn)
                }
            }
        }

        let lastRow = (height - 1) * width
        var end = -1
        var score = none
        for column in 0 ..< width where scores[lastRow + column] > score {
            score = scores[lastRow + column]
            end = column
        }
        guard end >= 0 else {
            return nil
        }
        var positions = [Int](repeating: 0, count: height)
        var column = end
        for row in stride(from: height - 1, through: 0, by: -1) {
            positions[row] = column
            column = Int(from[row * width + column])
        }
        return PaletteMatch(kind: .scattered, score: score - (width - height), positions: positions)
    }
}

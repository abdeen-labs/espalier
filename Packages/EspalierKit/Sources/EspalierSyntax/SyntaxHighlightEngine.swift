// Parses with tree-sitter and runs the grammars' highlight queries. It takes
// a file's lines and the lines the diff shows, stops reading where it can
// after the last of them, and gives ranges only for the lines asked for.
//
// Overlapping captures resolve as in tree-sitter's highlighter
// (highlight/src/lib.rs): captures apply in the order tree-sitter's query
// cursor gives them, each over the ones before it. Captures come by where
// they start, and for one place by pattern, so when several patterns
// capture the same node, the last one colors it (the first one for Go and
// JSON, whose queries are written that way; `PatternPrecedence`), and a
// node inside another takes its own color over the outer node's. (Where
// both start at the same place, the cursor's order decides: TOML colors a
// whole `key = value` pair as a property, so its key is one.) An injected
// language's colors go over the language it's injected into, and emphasis
// in Markdown keeps the color around it (a heading's, a link's).

import TreeSitter

/// A highlighted range of a line: its UTF-16 code units, relative to the
/// line's start, and what it is.
public struct HighlightedRange: Sendable, Hashable {
    public var range: Range<Int>
    public var category: SyntaxCategory

    public init(range: Range<Int>, category: SyntaxCategory) {
        self.range = range
        self.category = category
    }
}

/// Colors files with tree-sitter. One engine compiles each language's
/// queries once and can highlight on any number of threads at once.
public final class SyntaxHighlightEngine: Sendable {
    /// The engine the app uses.
    public static let shared = SyntaxHighlightEngine()

    /// The most of a file the app colors, in UTF-8 bytes.
    public static let maxContentLength = 1024 * 1024

    /// The lines that start within the first `maxContentLength` bytes.
    public static func linesWithinLimit(_ lines: [String]) -> [String] {
        var bytes = 0
        for (index, line) in lines.enumerated() {
            if bytes >= maxContentLength {
                return Array(lines[..<index])
            }
            bytes += line.utf8.count + 1
        }
        return lines
    }

    let cache = LanguageCache()

    public init() {}

    /// The highlighted ranges of the lines `lineFilter` names (zero-based),
    /// by line, in order and not overlapping. A line with nothing
    /// highlighted has no entry. Throws `CancellationError` when the task
    /// is cancelled, and `HighlightError` when the grammar's queries can't
    /// be used.
    public func highlight(_ lines: [String], grammar: Grammar, lineFilter: Set<Int>) throws -> [Int: [HighlightedRange]] {
        guard let run = try highlightRun(lines, spec: LanguageSpec(grammar: grammar), lineFilter: lineFilter) else {
            return [:]
        }
        return run.ranges()
    }

    /// The capture name that colors each range (tests compare them with
    /// the grammars' own highlight tests).
    func captureNames(_ lines: [String], spec: LanguageSpec, lineFilter: Set<Int>) throws -> [Int: [(range: Range<Int>, name: String)]] {
        guard let run = try highlightRun(lines, spec: spec, lineFilter: lineFilter) else {
            return [:]
        }
        var result: [Int: [(range: Range<Int>, name: String)]] = [:]
        for (line, spans) in run.spans(keepingPlain: true) {
            result[line] = spans.map { (range: $0.range, name: run.styles[Int($0.style)].name) }
        }
        return result
    }

    private func highlightRun(_ lines: [String], spec: LanguageSpec, lineFilter: Set<Int>) throws -> HighlightRun? {
        try Task.checkCancellation()
        let requested = lineFilter.filter { $0 >= 0 && $0 < lines.count }.sorted()
        guard !requested.isEmpty else {
            return nil
        }
        let run = HighlightRun(source: SourceText(lines: lines), requested: requested, cache: cache)
        if let compiled = cache.compiledIfReady(spec) {
            let language = try compiled.get()
            try run.highlight(language, tree: run.parseRoot(language.language))
            return run
        }
        // The first file in a language: its queries compile on another
        // thread while this one parses.
        cache.compileInBackground(spec)
        let tree = try run.parseRoot(LanguageHandle(pointer: spec.language()))
        let language = try cache.compiled(spec).get()
        try run.highlight(language, tree: tree)
        return run
    }
}

/// One highlight request: the parser, the cursor, and the painted styles.
final class HighlightRun {
    struct Style {
        let name: String
        let category: SyntaxCategory

        /// Emphasis has no color of its own: inside a heading or a link's
        /// text, it keeps theirs.
        var isTransparent: Bool {
            category == .emphasis || category == .strong
        }
    }

    /// How deep injections nest (Markdown, its code block's language, and
    /// one more).
    static let maximumDepth = 3
    /// Requested lines this close together are queried as one span.
    static let spanGap = 16

    let source: SourceText
    let requested: [Int]
    let cache: LanguageCache
    /// Where the requested lines are, in code units: runs of lines close
    /// together, each queried on its own.
    let spans: [Range<Int>]
    /// From the first requested line's start to the last one's end: what
    /// `paint` covers.
    let extent: Range<Int>

    private let parser = ParserHandle()
    private let cursor = QueryCursorHandle()
    private let evaluator: PredicateEvaluator
    /// The styles of captures, by ID; 0 is none.
    private(set) var styles: [Style] = [Style(name: "", category: .plain)]
    private var styleIDs: [String: [UInt16]] = [:]
    /// Each code unit's style in `extent`.
    private var paint: [UInt16]
    /// Injected layers already parsed, by their content's range.
    private var injected: Set<NodeKey> = []

    init(source: SourceText, requested: [Int], cache: LanguageCache) {
        self.source = source
        self.requested = requested
        self.cache = cache
        evaluator = PredicateEvaluator(source: source)
        var spans: [Range<Int>] = []
        var first = requested[0]
        var last = first
        for line in requested.dropFirst() {
            if line - last > Self.spanGap {
                spans.append(source.lineStarts[first]..<source.lineRange(last).upperBound)
                first = line
            }
            last = line
        }
        spans.append(source.lineStarts[first]..<source.lineRange(last).upperBound)
        self.spans = spans
        extent = spans[0].lowerBound..<spans[spans.count - 1].upperBound
        paint = [UInt16](repeating: 0, count: extent.count)
    }

    /// Paints the file's tree (`parseRoot`) and the languages injected in
    /// it.
    func highlight(_ language: CompiledLanguage, tree: TreeHandle) throws {
        try Task.checkCancellation()
        try highlight(language, tree: tree, ranges: nil, depth: 0)
    }

    // MARK: Parsing

    /// Parses the file, or only as much of it as the requested lines need:
    /// when they end in the first half of a long file, up to the first
    /// line after them that starts a top-level declaration (a line at the
    /// left margin after a blank one). The shorter parse stands only if it
    /// has no syntax errors, so nothing the cut left open (a comment, a
    /// string, a block) changed how the requested lines parse.
    func parseRoot(_ language: LanguageHandle) throws -> TreeHandle {
        if let cut = prefixCut() {
            let tree = try source.parse(with: parser, language: language, unitCount: source.lineStarts[cut])
            if !ts_node_has_error(tree.rootNode) {
                return tree
            }
            try Task.checkCancellation()
        }
        return try source.parse(with: parser, language: language)
    }

    /// The line to stop parsing before, if parsing less is worth it.
    func prefixCut() -> Int? {
        let lineCount = source.lineCount
        let last = requested[requested.count - 1]
        guard lineCount >= 2_000, last < lineCount / 2 else {
            return nil
        }
        let limit = lineCount * 3 / 4
        var line = last + 2
        while line < limit {
            if isBlank(line - 1), startsAtMargin(line) {
                return line
            }
            line += 1
        }
        return nil
    }

    private func isBlank(_ line: Int) -> Bool {
        source.lineRange(line).allSatisfy { [0x20, 0x09, 0x0D, 0x0C].contains(source.units[$0]) }
    }

    private func startsAtMargin(_ line: Int) -> Bool {
        let range = source.lineRange(line)
        guard let first = range.first else {
            return false
        }
        return ![0x20, 0x09, 0x0D, 0x0C].contains(source.units[first])
    }

    // MARK: Painting captures

    /// Paints a layer's captures in the requested spans, then the
    /// languages injected there, over them. An injected layer paints only
    /// the text it parsed (its ranges): where one of its nodes spans text
    /// it skipped (a template's `${…}`, PHP code between HTML), that text
    /// keeps its own colors.
    private func highlight(_ language: CompiledLanguage, tree: TreeHandle, ranges: [TSRange]?, depth: Int) throws {
        // Spans of empty lines have nothing to paint (and an empty byte
        // range would mean the whole file to the query cursor).
        var layerSpans = spans.filter { !$0.isEmpty }
        if let ranges {
            layerSpans = Self.intersect(layerSpans, ranges.map { range in
                Int(range.start_byte / 2)..<Int(min(range.end_byte, UInt32(source.units.count * 2)) / 2)
            })
        }
        guard !layerSpans.isEmpty else {
            return
        }

        var locals: Set<NodeKey> = []
        if language.usesLocals, let query = language.locals {
            locals = try LocalVariables.analyze(
                query, tree: tree, source: source, endUnit: layerSpans[layerSpans.count - 1].upperBound,
                cursor: cursor, evaluator: evaluator
            )
        }

        let ids = styleIDs(for: language)
        let transparent = styles.map(\.isTransparent)
        let patterns = language.highlights.predicates.patterns
        let regexes = language.highlights.predicates.regexes
        let firstWins = language.spec.precedence == .firstWins
        let query = language.highlights.query.pointer
        let root = tree.rootNode
        let base = extent.lowerBound
        var match = TSQueryMatch()
        var captureIndex: UInt32 = 0
        var steps = 0
        for span in layerSpans {
            try Task.checkCancellation()
            ts_query_cursor_set_byte_range(cursor.pointer, UInt32(span.lowerBound * 2), UInt32(span.upperBound * 2))
            ts_query_cursor_exec(cursor.pointer, query, root)
            // Whether each match passed its predicates (a match's captures
            // come one at a time, between other matches' captures).
            var verdicts: [UInt32: Bool] = [:]
            var previousNode: TSNode?
            try paint.withUnsafeMutableBufferPointer { buffer in
                while ts_query_cursor_next_capture(cursor.pointer, &match, &captureIndex) {
                    steps += 1
                    if steps & 0x3FF == 0, Task.isCancelled {
                        throw CancellationError()
                    }
                    let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
                    let capture = captures[Int(captureIndex)]
                    let style = ids[Int(capture.index)]
                    guard style != 0 else {
                        continue
                    }
                    let pattern = patterns[Int(match.pattern_index)]
                    if !pattern.predicates.isEmpty || pattern.isNotLocal {
                        let passed: Bool
                        if let verdict = verdicts[match.id] {
                            passed = verdict
                        } else {
                            passed = (pattern.predicates.isEmpty || evaluator.satisfies(pattern.predicates, regexes: regexes, captures: captures))
                                && !(pattern.isNotLocal && captures.contains { locals.contains(NodeKey($0.node)) })
                            verdicts[match.id] = passed
                        }
                        guard passed else {
                            continue
                        }
                    }
                    // With the first pattern winning, a later pattern's
                    // capture of the node just colored is dropped.
                    if firstWins, let previousNode, ts_node_eq(previousNode, capture.node) {
                        continue
                    }
                    previousNode = capture.node
                    let start = max(capture.node.startUnit, span.lowerBound) - base
                    let end = min(capture.node.endUnit, span.upperBound) - base
                    guard start < end else {
                        continue
                    }
                    if transparent[Int(style)] {
                        for index in start..<end where buffer[index] == 0 {
                            buffer[index] = style
                        }
                    } else {
                        for index in start..<end {
                            buffer[index] = style
                        }
                    }
                }
            }
        }

        if depth < Self.maximumDepth, let injections = language.injections {
            try inject(injections, tree: tree, spans: layerSpans, parentRanges: ranges ?? InjectionRanges.document, depth: depth)
        }
    }

    /// Highlights the languages injected in the requested spans: the
    /// combined injections' documents, then each other injected node.
    private func inject(_ injections: InjectionQuery, tree: TreeHandle, spans layerSpans: [Range<Int>], parentRanges: [TSRange], depth: Int) throws {
        if let combined = injections.combined {
            try injectCombined(injections, combined, tree: tree, parentRanges: parentRanges, depth: depth)
        }
        guard let query = injections.compiled else {
            return
        }
        var sites: [InjectionSite] = []
        var match = TSQueryMatch()
        let patterns = query.predicates.patterns
        let regexes = query.predicates.regexes
        for span in layerSpans {
            ts_query_cursor_set_byte_range(cursor.pointer, UInt32(span.lowerBound * 2), UInt32(span.upperBound * 2))
            ts_query_cursor_exec(cursor.pointer, query.query.pointer, tree.rootNode)
            while ts_query_cursor_next_match(cursor.pointer, &match) {
                let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
                let pattern = patterns[Int(match.pattern_index)]
                if !pattern.predicates.isEmpty, !evaluator.satisfies(pattern.predicates, regexes: regexes, captures: captures) {
                    continue
                }
                guard let site = injections.site(match, in: query, source: source), injected.insert(NodeKey(site.content)).inserted else {
                    continue
                }
                sites.append(site)
            }
        }
        for site in sites {
            try Task.checkCancellation()
            guard intersectsRequestedLines(site.content.unitRange) else {
                continue
            }
            let ranges = InjectionRanges.intersect(parentRanges, [site.content], includesChildren: site.includesChildren)
            guard !ranges.isEmpty, case .success(let language) = cache.compiled(site.language) else {
                continue
            }
            let tree: TreeHandle
            do {
                tree = try source.parse(with: parser, language: language.language, ranges: ranges)
            } catch is HighlightError {
                continue
            }
            try highlight(language, tree: tree, ranges: ranges, depth: depth + 1)
        }
    }

    /// Highlights the documents a layer's combined injections make: for
    /// each pattern and language it names, the nodes from the start of the
    /// file to the end of the requested lines, parsed as one document when
    /// any of them is on a requested line.
    private func injectCombined(_ injections: InjectionQuery, _ query: CompiledQuery, tree: TreeHandle, parentRanges: [TSRange], depth: Int) throws {
        let patterns = query.predicates.patterns
        let regexes = query.predicates.regexes
        var documents: [CombinedInjection] = []
        var documentIndex: [String: Int] = [:]
        var seen: Set<NodeKey> = []
        var match = TSQueryMatch()
        ts_query_cursor_set_byte_range(cursor.pointer, 0, UInt32(extent.upperBound * 2))
        ts_query_cursor_exec(cursor.pointer, query.query.pointer, tree.rootNode)
        while ts_query_cursor_next_match(cursor.pointer, &match) {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            let pattern = patterns[Int(match.pattern_index)]
            if !pattern.predicates.isEmpty, !evaluator.satisfies(pattern.predicates, regexes: regexes, captures: captures) {
                continue
            }
            guard let site = injections.site(match, in: query, source: source), seen.insert(NodeKey(site.content)).inserted else {
                continue
            }
            let key = "\(match.pattern_index) \(site.language.id)"
            if let index = documentIndex[key] {
                documents[index].contents.append(site.content)
            } else {
                documentIndex[key] = documents.count
                documents.append(CombinedInjection(language: site.language, contents: [site.content], includesChildren: site.includesChildren))
            }
        }
        for document in documents {
            try Task.checkCancellation()
            guard document.contents.contains(where: { intersectsRequestedLines($0.unitRange) }) else {
                continue
            }
            let contents = document.contents.sorted { ts_node_start_byte($0) < ts_node_start_byte($1) }
            let ranges = InjectionRanges.intersect(parentRanges, contents, includesChildren: document.includesChildren)
            guard !ranges.isEmpty, case .success(let language) = cache.compiled(document.language) else {
                continue
            }
            let tree: TreeHandle
            do {
                tree = try source.parse(with: parser, language: language.language, ranges: ranges)
            } catch is HighlightError {
                continue
            }
            try highlight(language, tree: tree, ranges: ranges, depth: depth + 1)
        }
    }

    /// The parts of `spans` inside `ranges`, both in order and not
    /// overlapping, without empty ones.
    static func intersect(_ spans: [Range<Int>], _ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var spanIndex = 0
        var rangeIndex = 0
        while spanIndex < spans.count, rangeIndex < ranges.count {
            let span = spans[spanIndex]
            let range = ranges[rangeIndex]
            let lower = max(span.lowerBound, range.lowerBound)
            let upper = min(span.upperBound, range.upperBound)
            if lower < upper {
                result.append(lower..<upper)
            }
            if span.upperBound <= range.upperBound {
                spanIndex += 1
            } else {
                rangeIndex += 1
            }
        }
        return result
    }

    /// Whether any requested line overlaps `range`.
    private func intersectsRequestedLines(_ range: Range<Int>) -> Bool {
        // The first requested line that ends after the range starts.
        var low = 0
        var high = requested.count
        while low < high {
            let middle = (low + high) / 2
            if source.lineStarts[requested[middle] + 1] <= range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < requested.count && source.lineStarts[requested[low]] < max(range.upperBound, range.lowerBound + 1)
    }

    /// The style of each of a language's captures (0 for the ones that
    /// don't color).
    private func styleIDs(for language: CompiledLanguage) -> [UInt16] {
        if let ids = styleIDs[language.spec.id] {
            return ids
        }
        var ids: [UInt16] = []
        ids.reserveCapacity(language.captureRoles.count)
        for (index, role) in language.captureRoles.enumerated() {
            switch role {
            case .highlight(let category):
                ids.append(UInt16(styles.count))
                styles.append(Style(name: language.highlights.captureNames[index], category: category))
            case .ignored:
                ids.append(0)
            }
        }
        styleIDs[language.spec.id] = ids
        return ids
    }

    // MARK: Reading the lines

    /// A run of code units in a line with one style.
    struct Span {
        var range: Range<Int>
        var style: UInt16
    }

    /// The requested lines' runs of one style (without unpainted text, and
    /// without plain text unless asked).
    func spans(keepingPlain: Bool) -> [Int: [Span]] {
        let base = extent.lowerBound
        var result: [Int: [Span]] = [:]
        for line in requested {
            let range = source.lineRange(line)
            var lineSpans: [Span] = []
            var index = range.lowerBound
            while index < range.upperBound {
                let style = paint[index - base]
                var end = index + 1
                while end < range.upperBound, paint[end - base] == style {
                    end += 1
                }
                if style != 0, keepingPlain || styles[Int(style)].category != .plain {
                    lineSpans.append(Span(range: (index - range.lowerBound)..<(end - range.lowerBound), style: style))
                }
                index = end
            }
            if !lineSpans.isEmpty {
                result[line] = lineSpans
            }
        }
        return result
    }

    /// The requested lines' categories, with adjacent runs of one category
    /// joined.
    func ranges() -> [Int: [HighlightedRange]] {
        var result: [Int: [HighlightedRange]] = [:]
        for (line, lineSpans) in spans(keepingPlain: false) {
            var ranges: [HighlightedRange] = []
            ranges.reserveCapacity(lineSpans.count)
            for span in lineSpans {
                let category = styles[Int(span.style)].category
                if let last = ranges.last, last.category == category, last.range.upperBound == span.range.lowerBound {
                    ranges[ranges.count - 1].range = last.range.lowerBound..<span.range.upperBound
                } else {
                    ranges.append(HighlightedRange(range: span.range, category: category))
                }
            }
            result[line] = ranges
        }
        return result
    }
}

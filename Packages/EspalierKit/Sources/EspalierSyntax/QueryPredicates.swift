// The predicates and directives of tree-sitter queries, as tree-sitter's own
// highlighter evaluates them (the Rust binding's `satisfies_text_predicates`,
// `property_settings`, and `property_predicates`), plus Neovim's
// `has-ancestor?` and `has-parent?`, which Objective-C's queries use.
// Predicates tree-sitter doesn't evaluate either are ignored, as tree-sitter
// ignores them.

import Foundation
import TreeSitter

/// A predicate on a pattern's captured nodes.
enum TextPredicate {
    /// `#eq?` and friends with a string: the node's text equals it.
    case equals(capture: UInt32, literal: [UInt16], negated: Bool, any: Bool)
    /// `#eq?` with two captures: their texts are equal.
    case equalsCapture(capture: UInt32, other: UInt32, negated: Bool, any: Bool)
    /// `#match?` and friends: a regular expression finds a match in the
    /// node's text.
    case matches(capture: UInt32, regex: Int, negated: Bool, any: Bool)
    /// `#any-of?`: the node's text is one of the strings.
    case anyOf(capture: UInt32, literals: [[UInt16]], negated: Bool)
    /// `#has-ancestor?` (Neovim's): some ancestor is one of the node types.
    case hasAncestor(capture: UInt32, symbols: Set<TSSymbol>, negated: Bool)
    /// `#has-parent?` (Neovim's): the parent is one of the node types.
    case hasParent(capture: UInt32, symbols: Set<TSSymbol>, negated: Bool)
}

/// What a pattern says besides its captures.
struct PatternInfo {
    var predicates: [TextPredicate] = []
    /// `(#is-not? local)`: the pattern doesn't apply to local variables.
    var isNotLocal = false
    /// `(#set! key value)` settings, by key (a value may be absent).
    var settings: [String: String?] = [:]
}

/// A query's pattern information and its regular expressions.
struct QueryPredicates: Sendable {
    let patterns: [PatternInfo]
    let regexes: [QueryRegex]

    init(query: QueryHandle, language: LanguageHandle) throws {
        var regexes: [QueryRegex] = []
        var regexIndex: [String: Int] = [:]
        var patterns: [PatternInfo] = []
        patterns.reserveCapacity(query.patternCount)
        for pattern in 0..<query.patternCount {
            var info = PatternInfo()
            var count: UInt32 = 0
            guard let steps = ts_query_predicates_for_pattern(query.pointer, UInt32(pattern), &count), count > 0 else {
                patterns.append(info)
                continue
            }
            var arguments: [PredicateArgument] = []
            var name: String?
            for step in UnsafeBufferPointer(start: steps, count: Int(count)) {
                switch step.type {
                case TSQueryPredicateStepTypeDone:
                    if let name {
                        try Self.add(name, arguments, to: &info, query: query, language: language, regexes: &regexes, regexIndex: &regexIndex)
                    }
                    name = nil
                    arguments = []
                case TSQueryPredicateStepTypeCapture:
                    arguments.append(.capture(step.value_id))
                default:
                    let value = query.stringValue(step.value_id)
                    if name == nil {
                        name = value
                    } else {
                        arguments.append(.string(value))
                    }
                }
            }
            patterns.append(info)
        }
        self.patterns = patterns
        self.regexes = regexes
    }

    private enum PredicateArgument {
        case capture(UInt32)
        case string(String)

        var capture: UInt32? {
            if case .capture(let id) = self { id } else { nil }
        }

        var string: String? {
            if case .string(let value) = self { value } else { nil }
        }
    }

    private static func add(
        _ name: String,
        _ arguments: [PredicateArgument],
        to info: inout PatternInfo,
        query: QueryHandle,
        language: LanguageHandle,
        regexes: inout [QueryRegex],
        regexIndex: inout [String: Int]
    ) throws {
        switch name {
        case "eq?", "not-eq?", "any-eq?", "any-not-eq?":
            guard arguments.count == 2, let capture = arguments[0].capture else {
                return
            }
            let negated = name.contains("not-")
            let any = name.hasPrefix("any-")
            if let other = arguments[1].capture {
                info.predicates.append(.equalsCapture(capture: capture, other: other, negated: negated, any: any))
            } else if let literal = arguments[1].string {
                info.predicates.append(.equals(capture: capture, literal: Array(literal.utf16), negated: negated, any: any))
            }
        case "match?", "not-match?", "any-match?", "any-not-match?":
            guard arguments.count == 2, let capture = arguments[0].capture, let pattern = arguments[1].string else {
                return
            }
            let index: Int
            if let existing = regexIndex[pattern] {
                index = existing
            } else {
                index = regexes.count
                regexes.append(try QueryRegex(pattern))
                regexIndex[pattern] = index
            }
            info.predicates.append(.matches(capture: capture, regex: index, negated: name.contains("not-"), any: name.hasPrefix("any-")))
        case "any-of?", "not-any-of?":
            guard let capture = arguments.first?.capture else {
                return
            }
            let literals = arguments.dropFirst().compactMap { $0.string.map { Array($0.utf16) } }
            info.predicates.append(.anyOf(capture: capture, literals: literals, negated: name == "not-any-of?"))
        case "has-ancestor?", "not-has-ancestor?", "has-parent?", "not-has-parent?":
            guard let capture = arguments.first?.capture else {
                return
            }
            let types = Set(arguments.dropFirst().compactMap(\.string))
            let symbols = Self.symbols(named: types, in: language)
            let negated = name.hasPrefix("not-")
            if name.hasSuffix("ancestor?") {
                info.predicates.append(.hasAncestor(capture: capture, symbols: symbols, negated: negated))
            } else {
                info.predicates.append(.hasParent(capture: capture, symbols: symbols, negated: negated))
            }
        case "is-not?":
            if arguments.first?.string == "local" {
                info.isNotLocal = true
            }
        case "set!":
            // `(#set! key value)` or `(#set! @capture key value)`; the
            // highlighter reads the pattern's own settings.
            let strings = arguments.compactMap(\.string)
            if arguments.first?.capture == nil, let key = strings.first {
                info.settings[key] = strings.count > 1 ? strings[1] : nil as String?
            }
        default:
            // `is?`, `offset!`, and predicates tree-sitter doesn't know
            // don't filter matches.
            break
        }
    }

    /// Every symbol whose node type is one of `names` (aliases included).
    private static func symbols(named names: Set<String>, in language: LanguageHandle) -> Set<TSSymbol> {
        var symbols: Set<TSSymbol> = []
        let count = ts_language_symbol_count(language.pointer)
        for symbol in 0..<count {
            let id = TSSymbol(symbol)
            guard let name = ts_language_symbol_name(language.pointer, id) else {
                continue
            }
            if names.contains(String(cString: name)) {
                symbols.insert(id)
            }
        }
        return symbols
    }
}

/// Evaluates predicates for one highlight request.
final class PredicateEvaluator {
    private let source: SourceText
    private var regexResults: [RegexKey: Bool] = [:]

    private struct RegexKey: Hashable {
        let regex: Int
        let text: String
    }

    init(source: SourceText) {
        self.source = source
    }

    /// Whether a match satisfies its pattern's predicates.
    func satisfies(_ predicates: [TextPredicate], regexes: [QueryRegex], captures: UnsafeBufferPointer<TSQueryCapture>) -> Bool {
        for predicate in predicates {
            switch predicate {
            case .equals(let capture, let literal, let negated, let any):
                let result = evaluate(capture, captures, any: any) { node in
                    source.text(node.unitRange, equals: literal) != negated
                }
                if !result {
                    return false
                }
            case .equalsCapture(let capture, let other, let negated, let any):
                guard let otherNode = captures.first(where: { $0.index == other })?.node else {
                    continue
                }
                let otherText = Array(source.units[otherNode.unitRange])
                let result = evaluate(capture, captures, any: any) { node in
                    source.text(node.unitRange, equals: otherText) != negated
                }
                if !result {
                    return false
                }
            case .matches(let capture, let regex, let negated, let any):
                let result = evaluate(capture, captures, any: any) { node in
                    matches(regexes[regex], index: regex, node.unitRange) != negated
                }
                if !result {
                    return false
                }
            case .anyOf(let capture, let literals, let negated):
                let result = evaluate(capture, captures, any: false) { node in
                    let range = node.unitRange
                    let found = literals.contains { source.text(range, equals: $0) }
                    return found != negated
                }
                if !result {
                    return false
                }
            case .hasAncestor(let capture, let symbols, let negated):
                let result = evaluate(capture, captures, any: false) { node in
                    hasAncestor(node, in: symbols) != negated
                }
                if !result {
                    return false
                }
            case .hasParent(let capture, let symbols, let negated):
                let result = evaluate(capture, captures, any: false) { node in
                    let parent = ts_node_parent(node)
                    let found = !ts_node_is_null(parent) && symbols.contains(ts_node_symbol(parent))
                    return found != negated
                }
                if !result {
                    return false
                }
            }
        }
        return true
    }

    /// Whether every node `capture` captured (or, with `any`, one of them)
    /// passes `test`. A capture absent from the match passes, as in
    /// tree-sitter.
    private func evaluate(_ capture: UInt32, _ captures: UnsafeBufferPointer<TSQueryCapture>, any: Bool, _ test: (TSNode) -> Bool) -> Bool {
        var sawNode = false
        for item in captures where item.index == capture {
            sawNode = true
            let passed = test(item.node)
            if any, passed {
                return true
            }
            if !any, !passed {
                return false
            }
        }
        return any ? !sawNode : true
    }

    private func matches(_ regex: QueryRegex, index: Int, _ range: Range<Int>) -> Bool {
        switch regex.engine {
        case .simple(let simple):
            return source.units.withUnsafeBufferPointer { buffer in
                simple.firstMatch(in: UnsafeBufferPointer(rebasing: buffer[range]))
            }
        case .foundation(let expression):
            let text = source.string(range)
            let key = RegexKey(regex: index, text: text)
            if let known = regexResults[key] {
                return known
            }
            let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            regexResults[key] = result
            return result
        }
    }

    /// Whether a node of one of `symbols` contains `node` (walking down
    /// from the root, which is cheaper than asking for each parent).
    private func hasAncestor(_ node: TSNode, in symbols: Set<TSSymbol>) -> Bool {
        var current = ts_tree_root_node(node.tree)
        while !ts_node_is_null(current), !ts_node_eq(current, node) {
            if symbols.contains(ts_node_symbol(current)) {
                return true
            }
            current = ts_node_child_with_descendant(current, node)
        }
        return false
    }
}

/// A regular expression from a `#match?` predicate. Tree-sitter evaluates
/// them with Rust's `regex` crate; the simple ones the grammars use
/// (anchors, classes, alternatives of words, `*`, `+`, `?`) run on a small
/// matcher over UTF-16 with the same meaning, and anything else falls back
/// to `NSRegularExpression`.
struct QueryRegex: @unchecked Sendable {
    enum Engine {
        case simple(SimpleRegex)
        case foundation(NSRegularExpression)
    }

    let pattern: String
    let engine: Engine

    init(_ pattern: String) throws {
        self.pattern = pattern
        if let simple = SimpleRegex(pattern) {
            engine = .simple(simple)
        } else {
            engine = .foundation(try NSRegularExpression(pattern: pattern))
        }
    }
}

/// A backtracking matcher for a small regular expression language, over
/// UTF-16 code units: literal characters and escapes, `.` (anything but a
/// newline), classes (`[A-Z_]`, `[^/]`, `\d`, `\w`, `\s`), groups of
/// alternatives (`(a|b)`), `*`, `+`, `?`, and the anchors `^` and `$` (the
/// start and end of the text, as Rust's `regex` has them without the
/// multi-line flag). Returns nil for anything else.
struct SimpleRegex {
    indirect enum Node {
        case unit(UInt16)
        case any
        case set(UnitSet)
        case start
        case end
        case group([[Node]])
        case repeated(Node, min: Int, max: Int?)
    }

    let nodes: [Node]

    init?(_ pattern: String) {
        var parser = Parser(units: Array(pattern.utf16))
        guard let nodes = parser.parseAlternatives(), parser.isAtEnd else {
            return nil
        }
        self.nodes = nodes.count == 1 ? nodes[0] : [.group(nodes)]
    }

    /// Whether the expression matches somewhere in `text`.
    func firstMatch(in text: UnsafeBufferPointer<UInt16>) -> Bool {
        if case .start = nodes.first {
            return match(nodes, 0, 0, text) { _ in true }
        }
        for position in 0...text.count {
            if match(nodes, 0, position, text, { _ in true }) {
                return true
            }
        }
        return false
    }

    private func match(_ nodes: [Node], _ index: Int, _ position: Int, _ text: UnsafeBufferPointer<UInt16>, _ then: (Int) -> Bool) -> Bool {
        guard index < nodes.count else {
            return then(position)
        }
        switch nodes[index] {
        case .unit(let unit):
            guard position < text.count, text[position] == unit else {
                return false
            }
            return match(nodes, index + 1, position + 1, text, then)
        case .any:
            guard position < text.count, text[position] != 0x0A else {
                return false
            }
            return match(nodes, index + 1, position + 1, text, then)
        case .set(let set):
            guard position < text.count, set.contains(text[position]) else {
                return false
            }
            return match(nodes, index + 1, position + 1, text, then)
        case .start:
            return position == 0 && match(nodes, index + 1, position, text, then)
        case .end:
            return position == text.count && match(nodes, index + 1, position, text, then)
        case .group(let alternatives):
            for alternative in alternatives {
                if match(alternative, 0, position, text, { end in match(nodes, index + 1, end, text, then) }) {
                    return true
                }
            }
            return false
        case .repeated(let node, let min, let max):
            return repeatMatch(node, count: 0, min: min, max: max, position, text) { end in
                match(nodes, index + 1, end, text, then)
            }
        }
    }

    /// Greedy repetition with backtracking.
    private func repeatMatch(_ node: Node, count: Int, min: Int, max: Int?, _ position: Int, _ text: UnsafeBufferPointer<UInt16>, _ then: (Int) -> Bool) -> Bool {
        if max.map({ count < $0 }) ?? true {
            let advanced = match([node], 0, position, text) { end in
                end != position && repeatMatch(node, count: count + 1, min: min, max: max, end, text, then)
            }
            if advanced {
                return true
            }
        }
        return count >= min && then(position)
    }

    /// A set of code units: ranges and classes, possibly negated.
    struct UnitSet {
        var ranges: [ClosedRange<UInt16>] = []
        var classes: [Class] = []
        var negated = false

        enum Class {
            case digit, notDigit, word, notWord, space, notSpace
        }

        func contains(_ unit: UInt16) -> Bool {
            var found = ranges.contains { $0.contains(unit) }
            if !found {
                for value in classes where Self.isIn(value, unit) {
                    found = true
                    break
                }
            }
            return found != negated
        }

        static func isIn(_ value: Class, _ unit: UInt16) -> Bool {
            switch value {
            case .digit: isDigit(unit)
            case .notDigit: !isDigit(unit)
            case .word: isWord(unit)
            case .notWord: !isWord(unit)
            case .space: isSpace(unit)
            case .notSpace: !isSpace(unit)
            }
        }

        /// Unicode decimal digits, as Rust's `\d`.
        static func isDigit(_ unit: UInt16) -> Bool {
            if unit < 0x80 {
                return (0x30...0x39).contains(unit)
            }
            return Unicode.Scalar(unit)?.properties.generalCategory == .decimalNumber
        }

        /// Unicode word characters, as Rust's `\w`.
        static func isWord(_ unit: UInt16) -> Bool {
            if unit < 0x80 {
                return (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
            }
            guard let scalar = Unicode.Scalar(unit) else {
                return false
            }
            let properties = scalar.properties
            return properties.isAlphabetic || properties.generalCategory == .decimalNumber
                || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark
                || properties.generalCategory == .connectorPunctuation
        }

        static func isSpace(_ unit: UInt16) -> Bool {
            if unit < 0x80 {
                return unit == 0x20 || (0x09...0x0D).contains(unit)
            }
            return Unicode.Scalar(unit)?.properties.isWhitespace ?? false
        }
    }

    private struct Parser {
        let units: [UInt16]
        var position = 0

        var isAtEnd: Bool {
            position == units.count
        }

        private var current: UInt16? {
            position < units.count ? units[position] : nil
        }

        /// Alternatives separated by `|`, up to a `)` or the end.
        mutating func parseAlternatives() -> [[Node]]? {
            var alternatives: [[Node]] = []
            var sequence: [Node] = []
            while let unit = current, unit != 0x29 {
                position += 1
                var node: Node
                switch unit {
                case 0x7C: // |
                    alternatives.append(sequence)
                    sequence = []
                    continue
                case 0x5E: // ^
                    node = .start
                case 0x24: // $
                    node = .end
                case 0x2E: // .
                    node = .any
                case 0x28: // (
                    if current == 0x3F { // (? flags and non-capturing groups
                        return nil
                    }
                    guard let inner = parseAlternatives(), current == 0x29 else {
                        return nil
                    }
                    position += 1
                    node = .group(inner)
                case 0x5B: // [
                    guard let set = parseClass() else {
                        return nil
                    }
                    node = .set(set)
                case 0x5C: // backslash
                    guard let escaped = parseEscape() else {
                        return nil
                    }
                    node = escaped
                case 0x2A, 0x2B, 0x3F, 0x7B, 0x7D: // a quantifier with nothing before it, or braces
                    return nil
                default:
                    node = .unit(unit)
                }
                if let quantifier = current, [0x2A, 0x2B, 0x3F, 0x7B].contains(quantifier) {
                    switch quantifier {
                    case 0x2A: node = .repeated(node, min: 0, max: nil)
                    case 0x2B: node = .repeated(node, min: 1, max: nil)
                    case 0x3F: node = .repeated(node, min: 0, max: 1)
                    default: return nil // {n,m}
                    }
                    position += 1
                    if let lazy = current, [0x3F, 0x2A, 0x2B].contains(lazy) {
                        return nil // lazy or stacked quantifiers
                    }
                    if case .repeated(let inner, _, _) = node, case .start = inner {
                        return nil
                    }
                }
                sequence.append(node)
            }
            alternatives.append(sequence)
            return alternatives
        }

        private mutating func parseEscape() -> Node? {
            guard let unit = current else {
                return nil
            }
            position += 1
            switch unit {
            case 0x64: return .set(UnitSet(classes: [.digit]))
            case 0x44: return .set(UnitSet(classes: [.notDigit]))
            case 0x77: return .set(UnitSet(classes: [.word]))
            case 0x57: return .set(UnitSet(classes: [.notWord]))
            case 0x73: return .set(UnitSet(classes: [.space]))
            case 0x53: return .set(UnitSet(classes: [.notSpace]))
            case 0x6E: return .unit(0x0A)
            case 0x74: return .unit(0x09)
            default:
                // Escaped punctuation stands for itself; escaped letters
                // and digits mean something this matcher doesn't do.
                if (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit >= 0x80 {
                    return nil
                }
                return .unit(unit)
            }
        }

        private mutating func parseClass() -> UnitSet? {
            var set = UnitSet()
            if current == 0x5E {
                set.negated = true
                position += 1
            }
            var first = true
            while let unit = current {
                if unit == 0x5D, !first { // ]
                    position += 1
                    return set
                }
                first = false
                position += 1
                var lower: UInt16
                if unit == 0x5C {
                    guard let escaped = current else {
                        return nil
                    }
                    position += 1
                    switch escaped {
                    case 0x64: set.classes.append(.digit); continue
                    case 0x44: set.classes.append(.notDigit); continue
                    case 0x77: set.classes.append(.word); continue
                    case 0x57: set.classes.append(.notWord); continue
                    case 0x73: set.classes.append(.space); continue
                    case 0x53: set.classes.append(.notSpace); continue
                    case 0x6E: lower = 0x0A
                    case 0x74: lower = 0x09
                    default:
                        if (0x30...0x39).contains(escaped) || (0x41...0x5A).contains(escaped) || (0x61...0x7A).contains(escaped) || escaped >= 0x80 {
                            return nil
                        }
                        lower = escaped
                    }
                } else if unit == 0x5B {
                    return nil // nested classes and [:alpha:]
                } else {
                    lower = unit
                }
                if current == 0x2D, position + 1 < units.count, units[position + 1] != 0x5D {
                    position += 1
                    guard let upperUnit = current, upperUnit != 0x5C, upperUnit != 0x5B, upperUnit >= lower else {
                        return nil
                    }
                    position += 1
                    set.ranges.append(lower...upperUnit)
                } else {
                    set.ranges.append(lower...lower)
                }
            }
            return nil
        }
    }
}

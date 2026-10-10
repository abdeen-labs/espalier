// Ported in part from tree-sitter's highlight/src/lib.rs (`HighlightIter`'s
// local-variable tracking, `LocalScope`, `LocalDef`): which identifiers are
// local variables, so that highlight patterns marked `(#is-not? local)` skip
// them. JavaScript's queries use it for `require` and `console`, Ruby's to
// tell a method call without arguments from a local variable.
//
// Tree-sitter also colors a reference to a local the way its definition is
// colored; Espalier doesn't, because the definitions' colors (variables and
// parameters) are plain text anyway.

import TreeSitter

/// A node, by its range.
struct NodeKey: Hashable {
    let start: Int32
    let end: Int32

    init(_ node: TSNode) {
        start = Int32(truncatingIfNeeded: node.startUnit)
        end = Int32(truncatingIfNeeded: node.endUnit)
    }
}

enum LocalVariables {
    private struct Scope {
        var inherits: Bool
        var end: Int
        /// The definitions' names, and where each one's value ends (a
        /// reference before that doesn't see it).
        var definitions: [[UInt16]: [Int]] = [:]
    }

    /// The nodes that are local variables, among the captures of `query` in
    /// the tree up to `endUnit`: every definition, and every reference to a
    /// definition earlier in a scope that holds it.
    static func analyze(
        _ query: LocalsQuery,
        tree: TreeHandle,
        source: SourceText,
        endUnit: Int,
        cursor: QueryCursorHandle,
        evaluator: PredicateEvaluator
    ) throws -> Set<NodeKey> {
        let patterns = query.compiled.predicates.patterns
        let regexes = query.compiled.predicates.regexes
        ts_query_cursor_set_byte_range(cursor.pointer, 0, UInt32(endUnit * 2))
        ts_query_cursor_exec(cursor.pointer, query.compiled.query.pointer, tree.rootNode)
        defer {
            ts_query_cursor_set_byte_range(cursor.pointer, 0, UInt32.max)
        }

        var scopes = [Scope(inherits: false, end: Int.max)]
        var locals: Set<NodeKey> = []
        var match = TSQueryMatch()
        var captureIndex: UInt32 = 0
        var steps = 0
        while ts_query_cursor_next_capture(cursor.pointer, &match, &captureIndex) {
            steps += 1
            if steps & 0x3FF == 0, Task.isCancelled {
                throw CancellationError()
            }
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            let pattern = patterns[Int(match.pattern_index)]
            if !pattern.predicates.isEmpty, !evaluator.satisfies(pattern.predicates, regexes: regexes, captures: captures) {
                continue
            }
            let capture = captures[Int(captureIndex)]
            let range = capture.node.unitRange
            while scopes.count > 1, range.lowerBound > scopes[scopes.count - 1].end {
                scopes.removeLast()
            }
            switch capture.index {
            case query.scope:
                let inherits = (pattern.settings["local.scope-inherits"] ?? nil).map { $0 == "true" } ?? true
                scopes.append(Scope(inherits: inherits, end: range.upperBound))
            case query.definition:
                let name = Array(source.units[range])
                let valueEnd = captures.first { $0.index == query.definitionValue }?.node.endUnit ?? 0
                scopes[scopes.count - 1].definitions[name, default: []].append(valueEnd)
                locals.insert(NodeKey(capture.node))
            case query.reference:
                let key = NodeKey(capture.node)
                guard !locals.contains(key) else {
                    continue
                }
                let name = Array(source.units[range])
                for scope in scopes.reversed() {
                    if let ends = scope.definitions[name], ends.contains(where: { range.lowerBound >= $0 }) {
                        locals.insert(key)
                        break
                    }
                    if !scope.inherits {
                        break
                    }
                }
            default:
                break
            }
        }
        return locals
    }
}

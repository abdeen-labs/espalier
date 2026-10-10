// Owners for tree-sitter's C objects (parser, tree, query cursor, query),
// used by the highlighter. SwiftTreeSitter's wrappers keep their pointers
// private, and the highlighter's inner loops run on the C API directly.

import TreeSitter

/// A tree-sitter parser. Not thread-safe: one per highlight request.
final class ParserHandle {
    let pointer: OpaquePointer

    init() {
        pointer = ts_parser_new()
    }

    deinit {
        ts_parser_delete(pointer)
    }
}

/// A syntax tree.
final class TreeHandle {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ts_tree_delete(pointer)
    }

    var rootNode: TSNode {
        ts_tree_root_node(pointer)
    }
}

/// A query cursor. Not thread-safe: one per highlight request.
final class QueryCursorHandle {
    let pointer: OpaquePointer

    init() {
        pointer = ts_query_cursor_new()
    }

    deinit {
        ts_query_cursor_delete(pointer)
    }
}

/// A compiled query. Immutable once built, so cursors on several threads
/// can run it at once (as tree-sitter's own highlighter shares its
/// configurations).
final class QueryHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ts_query_delete(pointer)
    }

    var patternCount: Int {
        Int(ts_query_pattern_count(pointer))
    }

    var captureCount: Int {
        Int(ts_query_capture_count(pointer))
    }

    func captureName(_ index: Int) -> String {
        var length: UInt32 = 0
        guard let name = ts_query_capture_name_for_id(pointer, UInt32(index), &length) else {
            return ""
        }
        return String(cString: name)
    }

    func stringValue(_ index: UInt32) -> String {
        var length: UInt32 = 0
        guard let value = ts_query_string_value_for_id(pointer, index, &length) else {
            return ""
        }
        return String(cString: value)
    }
}

/// A language, as the grammar's C function gives it: a pointer to static
/// data, safe to share.
struct LanguageHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

extension TSNode {
    /// The node's range in UTF-16 code units (the trees are parsed from
    /// UTF-16, so a byte offset is twice a code unit offset).
    var unitRange: Range<Int> {
        Int(ts_node_start_byte(self)) / 2..<Int(ts_node_end_byte(self)) / 2
    }

    var startUnit: Int {
        Int(ts_node_start_byte(self)) / 2
    }

    var endUnit: Int {
        Int(ts_node_end_byte(self)) / 2
    }

    var isNull: Bool {
        ts_node_is_null(self)
    }
}

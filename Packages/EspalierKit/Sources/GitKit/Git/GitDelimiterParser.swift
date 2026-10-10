// Ported from desktop/app/src/lib/git/git-delimiter-parser.ts

import EspalierSupport
import Foundation

/// One parsed record: a value for every field the parser was created with,
/// keyed on the caller's own key type (usually an enum).
public struct DelimitedRecord<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let values: [Key: Value]

    init(_ values: [Key: Value]) {
        self.values = values
    }

    /// The value of `key`. Every key the parser was created with has one.
    public subscript(_ key: Key) -> Value {
        guard let value = values[key] else {
            preconditionFailure("\(key) is not one of the parser's fields")
        }
        return value
    }
}

/// The arguments to append to a `git log`-like call and the function that
/// parses its output. Returned by `createLogParser`.
public struct LogParser<Key: Hashable & Sendable>: Sendable {
    /// The arguments that need to be appended to the git call.
    public let formatArgs: [String]
    private let keys: [Key]

    init(keys: [Key], formatArgs: [String]) {
        self.keys = keys
        self.formatArgs = formatArgs
    }

    /// Parses the output of git, decoded as text.
    public func parse(_ value: String) -> [DelimitedRecord<Key, String>] {
        parseRecords(JSCompat.split(value, "\0"))
    }

    /// Parses the raw output of git.
    public func parse(_ value: Data) -> [DelimitedRecord<Key, Data>] {
        parseRecords(splitBuffer(value, "\0"))
    }

    /// The number of fields in a record (for output that interleaves other
    /// fields with the records, such as `--raw`).
    var fieldCount: Int {
        keys.count
    }

    /// A record of `fields`, one value per field in the parser's order (see
    /// `fieldCount`).
    func record<V: Sendable>(_ fields: ArraySlice<V>) -> DelimitedRecord<Key, V> {
        precondition(fields.count == keys.count, "a record needs \(keys.count) fields")
        var entry: [Key: V] = [:]
        for (key, value) in zip(keys, fields) {
            entry[key] = value
        }
        return DelimitedRecord(entry)
    }

    private func parseRecords<V: Sendable>(_ records: [V]) -> [DelimitedRecord<Key, V>] {
        var entries: [DelimitedRecord<Key, V>] = []

        var i = 0
        while i < records.count - keys.count {
            var entry: [Key: V] = [:]
            for (ix, key) in keys.enumerated() {
                entry[key] = records[i + ix]
            }
            entries.append(DelimitedRecord(entry))
            i += keys.count
        }

        return entries
    }
}

/// Create a new parser suitable for parsing --format output from commands such
/// as `git log`, `git stash`, and other commands that are not derived from
/// `ref-filter`.
///
/// Returns an object with the arguments that need to be appended to the git
/// call and the parse function itself
///
/// - Parameter fields: An object keyed on the friendly name of the value being
///   parsed with the value being the format string of said value.
///
///   Example:
///
///   `let parser = createLogParser([Field.sha: "%H"])`
public func createLogParser<Key: Hashable & Sendable>(_ fields: KeyValuePairs<Key, String>) -> LogParser<Key> {
    let keys = fields.map(\.key)
    let format = fields.map(\.value).joined(separator: "%x00")
    let formatArgs = ["-z", "--format=\(format)"]

    return LogParser(keys: keys, formatArgs: formatArgs)
}

/// The arguments to append to a `git for-each-ref`-like call and the
/// function that parses its output. Returned by `createForEachRefParser`.
public struct ForEachRefParser<Key: Hashable & Sendable>: Sendable {
    /// The arguments that need to be appended to the git call.
    public let formatArgs: [String]
    private let keys: [Key]

    init(keys: [Key], formatArgs: [String]) {
        self.keys = keys
        self.formatArgs = formatArgs
    }

    /// Parses the output of git.
    ///
    /// - Throws: `GitLibError` when a record isn't followed by a newline.
    public func parse(_ value: String) throws -> [DelimitedRecord<Key, String>] {
        let records = JSCompat.split(value, "\0")
        var entries: [DelimitedRecord<Key, String>] = []

        var entry: [Key: String]?
        var consumed = 0

        // start at 1 to avoid 0 modulo X problem. The first record is guaranteed
        // to be empty anyway (due to %00 at the start of --format)
        var i = 1
        while i < records.count - 1 {
            defer { i += 1 }

            if i % (keys.count + 1) == 0 {
                if !JSCompat.strictEquals(records[i], "\n") {
                    throw GitLibError("Expected newline")
                }
                continue
            }

            var current = entry ?? [:]
            let key = keys[consumed % keys.count]
            current[key] = records[i]
            entry = current
            consumed += 1

            if consumed % keys.count == 0 {
                entries.append(DelimitedRecord(current))
                entry = nil
            }
        }

        return entries
    }
}

/// Create a new parser suitable for parsing --format output from commands such
/// as `git for-each-ref`, `git branch`, and other commands that are not derived
/// from `git log`.
///
/// Returns an object with the arguments that need to be appended to the git
/// call and the parse function itself
///
/// - Parameter fields: An object keyed on the friendly name of the value being
///   parsed with the value being the format string of said value.
///
///   Example:
///
///   `let parser = createForEachRefParser([Field.sha: "%(objectname)"])`
public func createForEachRefParser<Key: Hashable & Sendable>(
    _ fields: KeyValuePairs<Key, String>
) -> ForEachRefParser<Key> {
    let keys = fields.map(\.key)
    let format = fields.map(\.value).joined(separator: "%00")
    let formatArgs = ["--format=%00\(format)%00"]

    return ForEachRefParser(keys: keys, formatArgs: formatArgs)
}

import Darwin

/// A string that compares and hashes by its exact contents, the way
/// JavaScript's `===`, `Map`, `Set`, and `Array.includes` treat strings.
///
/// Swift's `String` equality uses canonical equivalence, so "café" spelled
/// with a precomposed "é" equals "café" spelled with "e" and a combining
/// accent. Git treats those as two different paths (a repository committed
/// with decomposed names shows both on macOS). Keying a dictionary or set on
/// this type keeps them apart.
public struct ExactString: Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public static func == (lhs: ExactString, rhs: ExactString) -> Bool {
        let left = lhs.value.utf8
        let right = rhs.value.utf8
        // Strings stored as UTF-8 (all but some bridged from Foundation)
        // compare their bytes at once; walking the views element by element
        // is slow for strings that share long prefixes, such as refs.
        let compared = left.withContiguousStorageIfAvailable { leftBytes in
            right.withContiguousStorageIfAvailable { rightBytes in
                leftBytes.count == rightBytes.count
                    && (leftBytes.isEmpty || memcmp(leftBytes.baseAddress!, rightBytes.baseAddress!, leftBytes.count) == 0)
            }
        }
        if case let isEqual?? = compared {
            return isEqual
        }
        return left.elementsEqual(right)
    }

    public func hash(into hasher: inout Hasher) {
        var value = value
        value.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        // A byte that never occurs in UTF-8 ends the string, as in `String`'s
        // own hashing, so a hash that combines several values in a row (a
        // key, then its value) doesn't depend on where one string ends and
        // the next begins.
        hasher.combine(0xFF as UInt8)
    }
}

extension Sequence<String> {
    /// The elements as a set compared by code units (`new Set(strings)`).
    public var exactSet: Set<ExactString> {
        Set(map(ExactString.init))
    }
}

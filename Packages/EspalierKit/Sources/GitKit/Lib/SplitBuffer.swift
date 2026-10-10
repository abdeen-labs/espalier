// Ported from desktop/app/src/lib/split-buffer.ts

import Foundation

/// Splits `buffer` at every occurrence of `delimiter` (encoded as UTF-8),
/// keeping empty pieces and the trailing piece.
///
/// The pieces are copies whose indices start at zero.
public func splitBuffer(_ buffer: Data, _ delimiter: String) -> [Data] {
    let needle = Array(delimiter.utf8)
    precondition(!needle.isEmpty, "splitBuffer needs a non-empty delimiter")

    return buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Data] in
        let bytes = raw.bindMemory(to: UInt8.self)
        guard let base = bytes.baseAddress else {
            return [Data()]
        }

        var result: [Data] = []
        var start = 0
        var index = 0
        let last = bytes.count - needle.count
        while index <= last {
            guard let found = memchr(base + index, Int32(needle[0]), last - index + 1) else {
                break
            }
            let candidate = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            var offset = 1
            while offset < needle.count, bytes[candidate + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count {
                result.append(Data(bytes[start..<candidate]))
                start = candidate + needle.count
                index = start
            } else {
                index = candidate + 1
            }
        }
        if start <= bytes.count {
            result.append(Data(bytes[start...]))
        }
        return result
    }
}

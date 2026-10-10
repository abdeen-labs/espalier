// Ported from desktop/app/src/ui/diff/changed-range.ts
//
// The changed range inside a paired deleted and added line, drawn as a
// stronger tint. Ranges are in UTF-16 code units, as JavaScript's and
// NSString's are.

import Foundation
import GitKit

/// A range in a line's content, in UTF-16 code units.
nonisolated struct IntraLineRange: Sendable, Hashable {
    /// The starting location for the range.
    var location: Int
    /// The length of the range.
    var length: Int

    /// Get the maximum position in the range.
    var max: Int {
        location + length
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

/// The changed parts of a deleted line and the added line paired with it.
nonisolated struct IntraLineChange: Sendable, Hashable {
    /// The changed range of the deleted line.
    var before: IntraLineRange
    /// The changed range of the added line.
    var after: IntraLineRange
}

/// The longest line for which we'd try to calculate a line diff, this matches
/// GitHub.com's behavior.
nonisolated let maxIntraLineDiffStringLength = 1024

/// Get the length of the common substring between the two strings.
private nonisolated func commonLength(
    _ stringA: [UInt16],
    _ rangeA: IntraLineRange,
    _ stringB: [UInt16],
    _ rangeB: IntraLineRange,
    reverse: Bool
) -> Int {
    let max = min(rangeA.length, rangeB.length)
    let startA = reverse ? rangeA.max - 1 : rangeA.location
    let startB = reverse ? rangeB.max - 1 : rangeB.location
    let stride = reverse ? -1 : 1

    var length = 0
    while abs(length) < max {
        if stringA[startA + length] != stringB[startB + length] {
            break
        }
        length += stride
    }

    return abs(length)
}

/// Get the changed ranges in the strings, relative to each other.
nonisolated func relativeChanges(_ stringA: String, _ stringB: String) -> (stringARange: IntraLineRange, stringBRange: IntraLineRange) {
    relativeChanges(Array(stringA.utf16), Array(stringB.utf16))
}

/// `relativeChanges` on UTF-16 code units.
nonisolated func relativeChanges(_ stringA: [UInt16], _ stringB: [UInt16]) -> (stringARange: IntraLineRange, stringBRange: IntraLineRange) {
    var bRange = IntraLineRange(location: 0, length: stringB.count)
    var aRange = IntraLineRange(location: 0, length: stringA.count)

    let prefixLength = commonLength(stringB, bRange, stringA, aRange, reverse: false)
    bRange = IntraLineRange(location: bRange.location + prefixLength, length: bRange.length - prefixLength)
    aRange = IntraLineRange(location: aRange.location + prefixLength, length: aRange.length - prefixLength)

    let suffixLength = commonLength(stringB, bRange, stringA, aRange, reverse: true)
    bRange.length -= suffixLength
    aRange.length -= suffixLength

    return (aRange, bRange)
}

/// The ranges to highlight in a deleted line and the added line paired with
/// it, or nil when either is too long to compare
/// (`maxIntraLineDiffStringLength`, in UTF-16 code units).
nonisolated func intraLineChange(before lineBefore: String, after lineAfter: String) -> IntraLineChange? {
    let before = Array(lineBefore.utf16)
    let after = Array(lineAfter.utf16)
    guard before.count < maxIntraLineDiffStringLength, after.count < maxIntraLineDiffStringLength else {
        return nil
    }
    let changeRanges = relativeChanges(before, after)
    return IntraLineChange(before: changeRanges.stringARange, after: changeRanges.stringBRange)
}

/// The changed ranges of a deleted line and the added line paired with it.
nonisolated func intraLineChange(deleted: DocumentLine, added: DocumentLine) -> IntraLineChange? {
    guard deleted.info.utf16Count < maxIntraLineDiffStringLength, added.info.utf16Count < maxIntraLineDiffStringLength else {
        return nil
    }
    let change = relativeChanges(deleted.contentUTF16, added.contentUTF16)
    return IntraLineChange(before: change.stringARange, after: change.stringBRange)
}

// A plain version of the branch picker's scores, for
// BranchesEquivalenceTests to check the optimized code against.

import Foundation

/// The reference for `BranchFilter`'s scores.
enum ReferenceBranchFilter {
    /// Higher is better; nil when it doesn't match.
    static func score(_ name: String, _ filter: String) -> Int? {
        guard !filter.isEmpty else {
            return 0
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: filter, options: options.union(.anchored)) != nil {
            return 4
        }
        if let range = name.range(of: filter, options: options) {
            let previous = name[name.index(before: range.lowerBound)]
            return previous == "/" || previous == "-" || previous == "_" || previous == "." ? 3 : 2
        }
        // The filter's characters in order.
        var remaining = filter.lowercased()[...]
        for character in name.lowercased() where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty {
                return 1
            }
        }
        return nil
    }
}

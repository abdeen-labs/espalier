// Ported in part from desktop/app/src/ui/lib/filter-list.tsx
//
// An item stays when `FuzzyQuery` matches any of its texts. The
// repository popover and the clone lists filter this way; their order
// stays the groups'.

import Foundation

extension Array where Element == RepositoryListGroupItems {
    /// The groups with the items whose texts (title, and owner/name) match
    /// `filter`, dropping the groups left empty; all of them for an empty
    /// filter.
    public func filtered(by filter: String) -> [RepositoryListGroupItems] {
        guard let query = FuzzyQuery(filter) else {
            return self
        }
        return compactMap { group in
            let items = group.items.filter { item in item.text.contains { query.matches($0) } }
            return items.isEmpty ? nil : RepositoryListGroupItems(identifier: group.identifier, items: items)
        }
    }
}

extension Array where Element == CloneableRepositoryGroup {
    /// The groups with the repositories whose `owner/name` matches
    /// `filter`, dropping the groups left empty; all of them for an empty
    /// filter.
    public func filtered(by filter: String) -> [CloneableRepositoryGroup] {
        guard let query = FuzzyQuery(filter) else {
            return self
        }
        return compactMap { group in
            let items = group.items.filter { item in item.text.contains { query.matches($0) } }
            return items.isEmpty ? nil : CloneableRepositoryGroup(identifier: group.identifier, items: items)
        }
    }
}

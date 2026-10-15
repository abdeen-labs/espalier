/// An existing ref that keeps git from creating a ref with a new name in
/// the same namespace (local branches, or tags).
public struct RefNameConflict: Sendable, Equatable {
    /// The existing ref's name.
    public let existingName: String
    /// Whether the names are the same ignoring case; otherwise one name is
    /// a folder of the other (`feature` and `feature/x`).
    public let isSameName: Bool

    public init(existingName: String, isSameName: Bool) {
        self.existingName = existingName
        self.isSameName = isSameName
    }
}

/// The name among `existingNames` that keeps git from creating a ref named
/// `name` beside them, or nil.
///
/// Git keeps a ref in a file named by its name, so one name can't be a
/// folder of another (`feature` and `feature/x`), and on a case-insensitive
/// volume, as macOS's are by default, names that differ only in case are
/// one file. Names compare by their `/`-separated parts, ignoring case. A
/// name that is the same as `name` comes before one that nests.
public func refNameConflict(_ name: String, among existingNames: some Sequence<String>) -> RefNameConflict? {
    let parts = foldedRefNameParts(name)
    var nested: String?
    for existingName in existingNames {
        let existingParts = foldedRefNameParts(existingName)
        if existingParts == parts {
            return RefNameConflict(existingName: existingName, isSameName: true)
        }
        if nested == nil, existingParts.starts(with: parts) || parts.starts(with: existingParts) {
            nested = existingName
        }
    }
    return nested.map { RefNameConflict(existingName: $0, isSameName: false) }
}

/// `name`'s `/`-separated parts, lowercased. Split by scalar, so a part
/// starting with a combining mark still starts after its slash.
private func foldedRefNameParts(_ name: String) -> [String] {
    name.unicodeScalars
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { String(String.UnicodeScalarView($0)).lowercased() }
}

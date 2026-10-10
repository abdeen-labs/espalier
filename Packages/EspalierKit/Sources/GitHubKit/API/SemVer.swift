import Foundation

/// A semantic version, parsed the way node-semver's `semver.parse` does.
///
/// This is the subset GitHub Enterprise Server versions need: strict parsing,
/// precedence, and `satisfies` for ranges made of primitive comparators (`<`,
/// `<=`, `>`, `>=`, `=`), partial and x-range versions (`>= 3`, `3.1.x`), and
/// `||`. Tilde, caret, and hyphen ranges are not supported; the endpoint
/// constraints don't use them.
public struct SemVer: Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum PrereleaseIdentifier: Sendable, Hashable {
        case numeric(Int)
        case alphanumeric(String)
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [PrereleaseIdentifier]
    public let build: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [PrereleaseIdentifier] = [], build: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// `semver.parse(version)`: `nil` unless the string (trimmed, with an
    /// optional leading `v`) is a full `major.minor.patch` version with
    /// optional prerelease and build parts.
    public init?(_ version: String) {
        var rest = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        guard rest.count <= 256 else { return nil }
        if rest.first == "v" {
            rest = rest.dropFirst()
        }

        var build: [String] = []
        if let plus = rest.firstIndex(of: "+") {
            let identifiers = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy(Self.isIdentifier) else { return nil }
            build = identifiers.map(String.init)
            rest = rest[..<plus]
        }

        var prerelease: [PrereleaseIdentifier] = []
        if let dash = rest.firstIndex(of: "-") {
            let identifiers = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            for identifier in identifiers {
                guard Self.isIdentifier(identifier) else { return nil }
                if identifier.allSatisfy(\.isASCIIDigit) {
                    guard let number = Self.numericIdentifier(identifier) else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.alphanumeric(String(identifier)))
                }
            }
            rest = rest[..<dash]
        }

        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.numericIdentifier(parts[0]),
              let minor = Self.numericIdentifier(parts[1]),
              let patch = Self.numericIdentifier(parts[2])
        else { return nil }

        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease, build: build)
    }

    public var description: String {
        var version = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            version += "-" + prerelease.map {
                switch $0 {
                case .numeric(let number): String(number)
                case .alphanumeric(let string): string
                }
            }.joined(separator: ".")
        }
        return version
    }

    /// Precedence; build metadata is ignored.
    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        compare(lhs, rhs) < 0
    }

    public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    static func compare(_ lhs: SemVer, _ rhs: SemVer) -> Int {
        for (left, right) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] where left != right {
            return left < right ? -1 : 1
        }

        // A version without a prerelease has higher precedence than one with.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case (.numeric(let a), .numeric(let b)) where a != b:
                return a < b ? -1 : 1
            case (.alphanumeric(let a), .alphanumeric(let b)) where a != b:
                return a < b ? -1 : 1
            case (.numeric, .alphanumeric):
                return -1
            case (.alphanumeric, .numeric):
                return 1
            default:
                continue
            }
        }
        return lhs.prerelease.count == rhs.prerelease.count ? 0 : (lhs.prerelease.count < rhs.prerelease.count ? -1 : 1)
    }

    private static func isIdentifier(_ identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A numeric identifier: digits without a leading zero, at most
    /// `Number.MAX_SAFE_INTEGER`.
    private static func numericIdentifier(_ identifier: Substring) -> Int? {
        guard !identifier.isEmpty,
              identifier.allSatisfy(\.isASCIIDigit),
              identifier == "0" || identifier.first != "0",
              let value = Int(identifier),
              Double(value) <= maxSafeInteger
        else { return nil }
        return value
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

// MARK: - Ranges

extension SemVer {
    /// `semver.satisfies(version, range)`. `false` if the range can't be
    /// parsed.
    public func satisfies(_ range: String) -> Bool {
        guard let sets = SemVerRange.parse(range) else { return false }
        return sets.contains { set in SemVerRange.test(set, self) }
    }
}

private enum SemVerRange {
    enum Operator: String {
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case equal = "="
    }

    /// `nil` semver means "any version".
    struct Comparator {
        let op: Operator
        let semver: SemVer?

        func test(_ version: SemVer) -> Bool {
            guard let semver else { return true }
            let comparison = SemVer.compare(version, semver)
            switch op {
            case .lessThan: return comparison < 0
            case .lessThanOrEqual: return comparison <= 0
            case .greaterThan: return comparison > 0
            case .greaterThanOrEqual: return comparison >= 0
            case .equal: return comparison == 0
            }
        }
    }

    static func parse(_ range: String) -> [[Comparator]]? {
        var sets: [[Comparator]] = []
        for setString in range.components(separatedBy: "||") {
            // Join operators separated from their versions (`>= 3.1.0`).
            var tokens: [String] = []
            for token in setString.split(whereSeparator: \.isWhitespace).map(String.init) {
                if let last = tokens.last, Operator(rawValue: last) != nil {
                    tokens[tokens.count - 1] = last + token
                } else {
                    tokens.append(token)
                }
            }

            var comparators: [Comparator] = []
            for token in tokens {
                guard let parsed = comparatorsFor(token) else { return nil }
                comparators += parsed
            }
            sets.append(comparators.isEmpty ? [Comparator(op: .greaterThanOrEqual, semver: nil)] : comparators)
        }
        return sets
    }

    /// Expands one comparator, filling in partial versions the way
    /// node-semver's `replaceXRange` does.
    static func comparatorsFor(_ token: String) -> [Comparator]? {
        var rest = Substring(token)
        var op: Operator?
        for candidate in [Operator.greaterThanOrEqual, .lessThanOrEqual, .greaterThan, .lessThan, .equal]
        where rest.hasPrefix(candidate.rawValue) {
            op = candidate
            rest = rest.dropFirst(candidate.rawValue.count)
            break
        }
        if rest.first == "v" || rest.first == "=" {
            rest = rest.dropFirst()
        }

        let isWildcard: (Substring) -> Bool = { $0 == "x" || $0 == "X" || $0 == "*" }

        // A full version (with any prerelease) is a plain comparator.
        if let full = SemVer(String(rest)) {
            return [Comparator(op: op ?? .equal, semver: full)]
        }

        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int?] = []
        for part in parts {
            if isWildcard(part) {
                numbers.append(nil)
            } else if let number = Int(part), number >= 0 {
                numbers.append(number)
            } else {
                return nil
            }
        }
        while numbers.count < 3 {
            numbers.append(nil)
        }

        let lowerBoundPrerelease: [SemVer.PrereleaseIdentifier] = [.numeric(0)]
        guard var major = numbers[0] else {
            // `*`, `x`: anything, unless strictly above or below everything.
            if op == .greaterThan || op == .lessThan {
                return [Comparator(op: .lessThan, semver: SemVer(major: 0, minor: 0, patch: 0, prerelease: lowerBoundPrerelease))]
            }
            return [Comparator(op: .greaterThanOrEqual, semver: nil)]
        }
        let minorIsWildcard = numbers[1] == nil
        var minor = numbers[1] ?? 0
        var patch = numbers[2] ?? 0

        switch op {
        case .greaterThan:
            if minorIsWildcard {
                major += 1
                minor = 0
            } else {
                minor += 1
            }
            patch = 0
            return [Comparator(op: .greaterThanOrEqual, semver: SemVer(major: major, minor: minor, patch: patch))]
        case .lessThanOrEqual:
            if minorIsWildcard {
                major += 1
                minor = 0
            } else {
                minor += 1
            }
            patch = 0
            return [Comparator(op: .lessThan, semver: SemVer(major: major, minor: minor, patch: patch, prerelease: lowerBoundPrerelease))]
        case .lessThan:
            return [Comparator(op: .lessThan, semver: SemVer(major: major, minor: minor, patch: patch, prerelease: lowerBoundPrerelease))]
        case .greaterThanOrEqual:
            return [Comparator(op: .greaterThanOrEqual, semver: SemVer(major: major, minor: minor, patch: patch))]
        case .equal, nil:
            let upper = minorIsWildcard
                ? SemVer(major: major + 1, minor: 0, patch: 0, prerelease: lowerBoundPrerelease)
                : SemVer(major: major, minor: minor + 1, patch: 0, prerelease: lowerBoundPrerelease)
            return [
                Comparator(op: .greaterThanOrEqual, semver: SemVer(major: major, minor: minor, patch: patch)),
                Comparator(op: .lessThan, semver: upper),
            ]
        }
    }

    static func test(_ set: [Comparator], _ version: SemVer) -> Bool {
        guard set.allSatisfy({ $0.test(version) }) else { return false }

        // A prerelease version only satisfies a set that names a prerelease of
        // the same major.minor.patch.
        if !version.prerelease.isEmpty {
            return set.contains { comparator in
                guard let semver = comparator.semver, !semver.prerelease.isEmpty else { return false }
                return semver.major == version.major && semver.minor == version.minor && semver.patch == version.patch
            }
        }
        return true
    }
}

// Ported from desktop/app/src/models/git-author.ts

import EspalierSupport
import Foundation

/// `/^(.*?)\s+<(.*?)>/`
private let nameAddrPattern = JSCompat.regex(
    "^(\(JSCompat.dot)*?)\(JSCompat.whitespace)+<(\(JSCompat.dot)*?)>"
)

public struct GitAuthor: Hashable, Sendable, CustomStringConvertible {
    public static func parse(_ nameAddr: String) -> GitAuthor? {
        guard let m = JSCompat.match(nameAddr, nameAddrPattern), let name = m[1], let email = m[2] else {
            return nil
        }
        return GitAuthor(name: name, email: email)
    }

    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// `name <email>`.
    public var description: String {
        "\(name) <\(email)>"
    }
}

// Ported from desktop/app/src/lib/git/interpret-trailers.ts
//
// Only `Trailer` and `isCoAuthoredByTrailer`, which the models use.
// GitInterpretTrailers.swift parses and merges trailers with git.

/// A representation of a Git commit message trailer.
///
/// See git-interpret-trailers for more information.
import EspalierSupport

public struct Trailer: Hashable, Sendable {
    public let token: String
    public let value: String

    public init(token: String, value: String) {
        self.token = token
        self.value = value
    }
}

/// Gets a value indicating whether the trailer token is
/// Co-Authored-By. Does not validate the token value.
public func isCoAuthoredByTrailer(_ trailer: Trailer) -> Bool {
    JSCompat.strictEquals(trailer.token.lowercased(), "co-authored-by")
}

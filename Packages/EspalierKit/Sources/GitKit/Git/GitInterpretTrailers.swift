// Ported from desktop/app/src/lib/git/interpret-trailers.ts
//
// `Trailer` and `isCoAuthoredByTrailer` live in Models/Lib/Trailer.swift.

import EspalierSupport
import Foundation

/// Parse a string containing only unfolded trailers produced by
/// git-interpret-trailers --only-input --only-trailers --unfold or
/// a derivative such as git log --format="%(trailers:only,unfold)"
///
/// - Parameters:
///   - trailers: A string containing one well formed trailer per
///     line
///   - separators: A string containing all characters to use when
///     attempting to find the separator between token
///     and value in a trailer. See the configuration
///     option trailer.separators for more information
///
///     Also see getTrailerSeparatorCharacters.
public func parseRawUnfoldedTrailers(_ trailers: String, _ separators: String) -> [Trailer] {
    let lines = JSCompat.split(trailers, "\n")
    var parsedTrailers: [Trailer] = []

    for line in lines {
        if let trailer = parseSingleUnfoldedTrailer(line, separators) {
            parsedTrailers.append(trailer)
        }
    }

    return parsedTrailers
}

public func parseSingleUnfoldedTrailer(_ line: String, _ separators: String) -> Trailer? {
    // Separators are found by Unicode scalar, at their first position in the
    // line.
    let scalars = line.unicodeScalars
    for separator in separators.unicodeScalars {
        if let ix = scalars.firstIndex(of: separator), ix > scalars.startIndex {
            return Trailer(
                token: JSCompat.trim(String(scalars[..<ix])),
                value: JSCompat.trim(String(scalars[scalars.index(after: ix)...]))
            )
        }
    }

    return nil
}

/// Merge one or more commit message trailers into a commit message.
///
/// If no trailers are given this method will simply try to ensure that
/// any trailers that happen to be part of the raw message are formatted
/// in accordance with the configuration options set for trailers in
/// the given repository.
///
/// Note that configuration may be set so that duplicate trailers are
/// kept or discarded.
///
/// - Parameters:
///   - repository: The repository in which to run the interpret-
///     trailers command. Although not intuitive this
///     does matter as there are configuration options
///     available for the format, position, etc of commit
///     message trailers. See the manpage for
///     git-interpret-trailers for more information.
///   - commitMessage: A commit message with or without existing commit
///     message trailers into which to merge the trailers
///     given in the trailers parameter
///   - trailers: Zero or more trailers to merge into the commit message
///
/// - Returns: A commit message string where the provided trailers (if)
///   any have been merged into the commit message using the
///   configuration settings for trailers in the provided
///   repository.
public func mergeTrailers(
    _ repository: Repository,
    _ commitMessage: String,
    _ trailers: [Trailer],
    unfold: Bool = false
) async throws -> String {
    var args = ["interpret-trailers"]

    // See https://github.com/git/git/blob/ebf3c04b262aa/Documentation/git-interpret-trailers.txt#L129-L132
    args.append("--no-divider")

    if unfold {
        args.append("--unfold")
    }

    for trailer in trailers {
        args.append(contentsOf: ["--trailer", "\(trailer.token)=\(trailer.value)"])
    }

    let result = try await git(args, repository.path, "mergeTrailers", options: GitExecutionOptions(stdin: commitMessage))

    return result.stdout
}

// Ported from desktop/app/src/lib/squash/squashed-commit-description.ts

import EspalierSupport

/// The description to suggest for a squashed commit: the description of the
/// commit squashed onto (without co-authors), then the summary and
/// description of each squashed commit, separated by blank lines, leaving out
/// empty parts.
public func getSquashedCommitDescription(_ commits: [Commit], _ squashOnto: Commit) -> String {
    let commitMessages = commits.map { c in
        [JSCompat.trim(c.summary), JSCompat.trim(c.bodyNoCoAuthors)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    let descriptions = ([JSCompat.trim(squashOnto.bodyNoCoAuthors)] + commitMessages)
        .filter { !$0.isEmpty }

    return descriptions.joined(separator: "\n\n")
}

// Ported from desktop/app/src/lib/git/checkout-index.ts

import Foundation

/// Forcefully updates the working directory with information from the index
/// for a given set of files.
///
/// This method is essentially the same as running `git checkout -- files`
/// except by using `checkout-index` we can pass the files we want updated
/// on stdin, avoiding all issues with too long arguments.
///
/// Note that this function will not yield errors for paths that don't
/// exist in the index (-q).
///
/// - Parameters:
///   - repository: The repository in which to update the working directory
///     with information from the index
///   - paths: The relative paths in the working directory to update
///     with information from the index.
public func checkoutIndex(_ repository: Repository, _ paths: [String]) async throws {
    if paths.isEmpty {
        return
    }

    let options = GitExecutionOptions(
        stdin: paths.joined(separator: "\0"),
        successExitCodes: [0, 1]
    )

    try await git(
        ["checkout-index", "-f", "-u", "-q", "--stdin", "-z"],
        repository.path,
        "checkoutIndex",
        options: options
    )
}

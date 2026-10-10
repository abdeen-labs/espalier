// Ported from desktop/app/src/lib/git/refs.ts

import EspalierSupport
import Foundation

/// Format a local branch in the ref syntax, ensuring situations when the branch
/// is ambiguous are handled.
///
/// Examples:
///  - main -> refs/heads/main
///  - heads/Microsoft/main -> refs/heads/Microsoft/main
///
/// - Parameter name: The local branch name
public func formatAsLocalRef(_ name: String) -> String {
    if JSCompat.startsWith(name, "heads/") {
        // In some cases, Git will report this name explicitly to distinguish from
        // a remote ref with the same name - this ensures we format it correctly.
        return "refs/\(name)"
    } else if !JSCompat.startsWith(name, "refs/heads/") {
        // By default Git will drop the heads prefix unless absolutely necessary
        // - include this to ensure the ref is fully qualified.
        return "refs/heads/\(name)"
    } else {
        return name
    }
}

/// Read a symbolic ref from the repository.
///
/// Symbolic refs are used to point to other refs, similar to how symlinks work
/// for files. Because refs can be removed easily from a Git repository,
/// symbolic refs should only be used when absolutely necessary.
///
/// - Parameters:
///   - repository: The repository to lookup
///   - ref: The symbolic ref to resolve
///
/// - Returns: the canonical ref, if found, or `nil` if `ref` cannot be found or
///   is not a symbolic ref
public func getSymbolicRef(_ repository: Repository, _ ref: String) async throws -> String? {
    let result = try await git(
        ["symbolic-ref", "-q", ref],
        repository.path,
        "getSymbolicRef",
        options: GitExecutionOptions(
            //  - 1 is the exit code that Git throws in quiet mode when the ref is not a
            //    symbolic ref
            //  - 128 is the generic error code that Git returns when it can't find
            //    something
            successExitCodes: [0, 1, 128]
        )
    )

    if result.exitCode == 1 || result.exitCode == 128 {
        return nil
    }

    return JSCompat.trim(result.stdout)
}

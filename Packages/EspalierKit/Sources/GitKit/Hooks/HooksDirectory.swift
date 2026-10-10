import EspalierSupport
import Foundation

/// Fills the temporary hooks directory that `core.hooksPath` points at while
/// hooks are intercepted.
///
/// Each intercepted hook becomes a symbolic link to the hook proxy
/// (espalier-askpass), which git runs in the hook's place.
///
/// Every other hook in `repositoryHooksPath` is exposed too. Otherwise,
/// while any hook is intercepted, git couldn't see the repository's other
/// hooks and would silently skip them (for example `reference-transaction`
/// and `post-index-change` during a commit):
///
/// - An executable hook gets a small script that runs it by its own path
///   (`exec '<hook>' "$@"`), with git's arguments, standard input, and
///   environment, so its exit status still counts and scripts that find
///   their helpers relative to `$0` keep working.
/// - A hook that isn't executable gets a symbolic link, so git still ignores
///   it and still says why.
///
/// Git's `.sample` files and hidden files are skipped; git never runs them.
///
/// - Parameters:
///   - directory: The new, empty temporary hooks directory.
///   - interceptedHooks: The hooks to run through the proxy.
///   - proxyPath: The absolute path of the hook proxy.
///   - repositoryHooksPath: The repository's hooks directory, from
///     `getRepoHooksPath`.
public func populateHooksDirectory(
    _ directory: String,
    interceptedHooks: [String],
    proxyPath: String,
    repositoryHooksPath: String
) throws {
    let fileManager = FileManager.default

    for hook in interceptedHooks {
        try fileManager.createSymbolicLink(atPath: POSIXPath.join(directory, hook), withDestinationPath: proxyPath)
    }

    let intercepted = Set(interceptedHooks)
    guard let names = try? fileManager.contentsOfDirectory(atPath: repositoryHooksPath) else {
        return
    }

    for name in names where !intercepted.contains(name) && !name.hasPrefix(".") && !name.hasSuffix(".sample") {
        let hookPath = POSIXPath.join(repositoryHooksPath, name)

        // Like git, follow symbolic links, and skip anything that isn't a
        // file.
        var info = stat()
        guard stat(hookPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            continue
        }

        let exposedPath = POSIXPath.join(directory, name)
        if access(hookPath, X_OK) == 0 {
            let script = "#!/bin/sh\n# Written by Espalier. Runs the repository's hook.\nexec \(posixShellQuote(hookPath)) \"$@\"\n"
            guard fileManager.createFile(atPath: exposedPath, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: exposedPath])
            }
        } else {
            try fileManager.createSymbolicLink(atPath: exposedPath, withDestinationPath: hookPath)
        }
    }
}

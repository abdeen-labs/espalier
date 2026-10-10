// Ported from desktop/app/src/lib/git/checkout.ts

import Foundation

public typealias CheckoutProgressCallback = @Sendable (CheckoutProgress) -> Void

private let checkoutStepWeight = 0.9

private func getCheckoutArgs(_ progressCallback: CheckoutProgressCallback?) -> [String] {
    ["checkout"] + (progressCallback != nil ? ["--progress"] : [])
}

private func getBranchCheckoutArgs(_ branch: Branch) -> [String] {
    // Remote refs are starting points for -b: use the canonical ref so a leading
    // dash isn't parsed as an option. Local branches need their short name to
    // avoid detaching HEAD. The trailing -- separates paths, not branch targets.
    (branch.type == .remote ? ["-b", branch.nameWithoutRemote, branch.ref] : [branch.name]) + ["--"]
}

private func getCheckoutOpts(
    _ repository: Repository,
    _ title: String,
    _ target: String,
    _ currentRemote: Remote?,
    _ progressCallback: CheckoutProgressCallback?,
    _ initialDescription: String? = nil,
    gitHubHTMLURL: String?
) async -> GitExecutionOptions {
    let opts = GitExecutionOptions(
        env: await envForRemoteOperation(
            getFallbackUrlForProxyResolve(repository, currentRemote, gitHubHTMLURL: gitHubHTMLURL)
        ),
        expectedErrors: AuthenticationErrors
    )

    guard let progressCallback else {
        return opts
    }

    // Initial progress
    progressCallback(CheckoutProgress(
        value: 0,
        title: title,
        description: initialDescription ?? title,
        target: target
    ))

    var trackingOpts = opts
    trackingOpts.trackLFSProgress = true
    return await executionOptionsWithProgress(trackingOpts, CheckoutProgressParser()) { progress in
        if case .progress(let gitProgress) = progress {
            let description = gitProgress.details.text
            let value = progress.percent

            progressCallback(CheckoutProgress(
                value: value,
                title: title,
                description: description,
                target: target
            ))
        }
    }
}

/// Check out the given branch.
///
/// A remote branch is checked out as a new local branch of the same name
/// (without the remote) that tracks it.
///
/// - Parameters:
///   - repository: The repository in which the branch checkout should
///     take place
///   - branch: The branch that should be checked out
///   - currentRemote: The repository's current remote, for the proxy
///     lookup; see `getFallbackUrlForProxyResolve`.
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the checkout operation. When provided this
///     enables the '--progress' command line flag for
///     'git checkout'.
///   - allowFileProtocol: Whether submodules may be cloned from local paths.
///   - gitHubHTMLURL: The web URL of the repository's GitHub endpoint, if
///     any; see `getFallbackUrlForProxyResolve`.
@discardableResult
public func checkoutBranch(
    _ repository: Repository,
    _ branch: Branch,
    _ currentRemote: Remote?,
    _ progressCallback: CheckoutProgressCallback? = nil,
    allowFileProtocol: Bool = false,
    gitHubHTMLURL: String? = nil
) async throws -> Bool {
    let title = "Checking out branch \(branch.name)"
    let opts = await getCheckoutOpts(
        repository,
        title,
        branch.name,
        currentRemote,
        progressCallback.map { clampProgress(0, checkoutStepWeight, $0) },
        "Switching to Branch",
        gitHubHTMLURL: gitHubHTMLURL
    )

    let baseArgs = getCheckoutArgs(progressCallback)
    let args = baseArgs + getBranchCheckoutArgs(branch)

    try await git(args, repository.path, "checkoutBranch", options: opts)

    // Update submodules after checkout
    try await updateSubmodulesAfterOperation(
        repository,
        currentRemote,
        progressCallback.map { clampProgress(checkoutStepWeight, 1, $0) },
        CheckoutProgress.self,
        title,
        branch.name,
        allowFileProtocol,
        gitHubHTMLURL: gitHubHTMLURL
    )

    return true
}

/// Check out the given commit.
/// Literally invokes `git checkout <commit SHA>`.
///
/// - Parameters:
///   - repository: The repository in which the branch checkout should
///     take place
///   - commit: The commit that should be checked out
///   - currentRemote: The repository's current remote, for the proxy
///     lookup; see `getFallbackUrlForProxyResolve`.
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the checkout operation. When provided this
///     enables the '--progress' command line flag for
///     'git checkout'.
///   - allowFileProtocol: Whether submodules may be cloned from local paths.
///   - gitHubHTMLURL: The web URL of the repository's GitHub endpoint, if
///     any; see `getFallbackUrlForProxyResolve`.
@discardableResult
public func checkoutCommit(
    _ repository: Repository,
    _ commit: CommitOneLine,
    _ currentRemote: Remote?,
    _ progressCallback: CheckoutProgressCallback? = nil,
    allowFileProtocol: Bool = false,
    gitHubHTMLURL: String? = nil
) async throws -> Bool {
    let title = "Checking out commit"
    let target = shortenSHA(commit.sha)
    let opts = await getCheckoutOpts(
        repository,
        title,
        target,
        currentRemote,
        progressCallback.map { clampProgress(0, checkoutStepWeight, $0) },
        gitHubHTMLURL: gitHubHTMLURL
    )

    let baseArgs = getCheckoutArgs(progressCallback)
    let args = baseArgs + [commit.sha]

    try await git(args, repository.path, "checkoutCommit", options: opts)

    // Update submodules after checkout
    try await updateSubmodulesAfterOperation(
        repository,
        currentRemote,
        progressCallback.map { clampProgress(checkoutStepWeight, 1, $0) },
        CheckoutProgress.self,
        title,
        target,
        allowFileProtocol,
        gitHubHTMLURL: gitHubHTMLURL
    )

    return true
}

/// Check out the paths at HEAD.
///
/// The paths are literal pathspecs (`literalPathspec`), so `a*.txt` doesn't
/// also overwrite ab.txt's changes.
public func checkoutPaths(_ repository: Repository, _ paths: [String]) async throws {
    try await git(["checkout", "HEAD", "--"] + literalPathspecs(paths), repository.path, "checkoutPaths")
}

/// Check out either stage #2 (ours) or #3 (theirs) for a conflicted
/// file.
///
/// The path is a literal pathspec.
public func checkoutConflictedFile(
    _ repository: Repository,
    _ file: WorkingDirectoryFileChange,
    _ resolution: ManualConflictResolution
) async throws {
    try await git(
        ["checkout", "--\(resolution.rawValue)", "--", literalPathspec(file.path)],
        repository.path,
        "checkoutConflictedFile"
    )
}

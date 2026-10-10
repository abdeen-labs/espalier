// Ported from desktop/app/src/lib/helpers/default-branch.ts

/// The default branch name that Espalier will use when initializing a new
/// repository.
private let defaultBranchInEspalier = "main"

/// The name of the Git configuration variable which holds what
/// branch name Git will use when initializing a new repository.
private let defaultBranchSettingName = "init.defaultBranch"

/// Returns the configured default branch when creating new repositories
private func getConfiguredDefaultBranch() async throws -> String? {
    try await getGlobalConfigValue(defaultBranchSettingName)
}

/// Returns the configured default branch when creating new repositories
public func getDefaultBranch() async throws -> String {
    try await getConfiguredDefaultBranch() ?? defaultBranchInEspalier
}

/// Sets the configured default branch when creating new repositories.
///
/// - Parameter branchName: The default branch name to use.
public func setDefaultBranch(_ branchName: String) async throws {
    try await setGlobalConfigValue(defaultBranchSettingName, branchName)
}

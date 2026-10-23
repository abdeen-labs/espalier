// The checks made before committing, in order. The repository rules check
// runs first; GitHub/BranchRules.swift loads and evaluates the rules.

import Darwin
import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "commit")

/// GitHub's limit on the size of a pushed file (100 MiB).
let largeFileLimit = 100 * 1024 * 1024

extension CommitModel {
    /// The gates that need nothing but the model, in order, returning the
    /// commit's context.
    ///
    /// 0. The repository's rules, when they would stop the commit from being
    ///    pushed: `.precondition` with the composer's warning.
    /// 1. Something to commit (files, or allow-empty, or amending) and a
    ///    summary or the single-file placeholder; else `.precondition` with
    ///    the commit button's tooltip.
    /// 2. Co-authors who weren't found (`commitWithUnknownCoAuthors`).
    /// 3. Included files the filter hides, with `confirmCommitFilteredChanges`
    ///    on (`commitFilteredChanges`).
    func checkGates(
        _ files: [WorkingDirectoryFileChange],
        in repository: RepositoryModel,
        confirmed: Set<ConfirmationKind>
    ) async throws(OperationError) -> CommitContext {
        if case .rebase? = repository.gitState.inProgress {
            // No commit during a rebase: it's continued instead.
            throw OperationError(
                .precondition(repository.operations.current?.conflictsMessage ?? "Resolve conflicts to continue rebasing."),
                operation: .commit,
                repositoryID: repository.id,
                gitContext: .commit
            )
        }

        if let ruleFailure = await repository.gitHub.repoRuleCommitFailure() {
            throw OperationError(.precondition(ruleFailure), operation: .commit, repositoryID: repository.id, gitContext: .commit)
        }

        let summary = draft.summary
        // A single included file prepopulates the summary (never in tutorial
        // repositories).
        let prepopulateCommitSummary = files.count == 1 && !repository.record.isTutorialRepository
        let summaryOrPlaceholder = prepopulateCommitSummary && summary.isEmpty
            ? placeholderSummary(for: files[0])
            : summary

        let canCommit = ((!files.isEmpty || options.allowEmpty) && !summary.isEmpty) || prepopulateCommitSummary
        let canAmend = amending != nil && (!summary.isEmpty || prepopulateCommitSummary)
        if !canCommit && !canAmend {
            // The disabled commit button's tooltip.
            let message: String
            if isEmptyOrWhitespace(summaryOrPlaceholder) {
                message = "Enter a summary to commit"
            } else if repository.changes.workingDirectory.files.isEmpty {
                message = "There are no changes to commit."
            } else {
                message = "Select one or more files to commit"
            }
            throw OperationError(.precondition(message), operation: .commit, repositoryID: repository.id, gitContext: .commit)
        }

        try checkCoAuthorAndFilterGates(in: repository, confirmed: confirmed)

        return CommitContext(
            summary: summaryOrPlaceholder,
            description: draft.description,
            amend: amending != nil,
            trailers: coAuthorTrailers(in: repository)
        )
    }

    /// Gates 2 and 3: co-authors who weren't found, and included files the
    /// filter hides. Assisted commits ask them too.
    func checkCoAuthorAndFilterGates(in repository: RepositoryModel, confirmed: Set<ConfirmationKind>) throws(OperationError) {
        // Co-authors count only while the co-author field shows.
        if draft.showCoAuthoredBy, !confirmed.contains(.commitWithUnknownCoAuthors) {
            let unknown = draft.coAuthors.compactMap { author -> String? in
                if case .unknown(let unknown) = author { unknown.username } else { nil }
            }
            if !unknown.isEmpty {
                throw OperationError(
                    .confirmationRequired(.commitWithUnknownCoAuthors(unknown)),
                    operation: .commit,
                    repositoryID: repository.id,
                    gitContext: .commit
                )
            }
        }

        if !confirmed.contains(.commitFilteredChanges), repository.app?.preferences.confirmCommitFilteredChanges ?? true {
            let hidden = repository.changes.includedFilesHiddenByFilter
            if !hidden.isEmpty {
                throw OperationError(
                    .confirmationRequired(.commitFilteredChanges(hiddenPaths: hidden.map(\.path))),
                    operation: .commit,
                    repositoryID: repository.id,
                    gitContext: .commit
                )
            }
        }
    }

    /// The gates that look at the files, after the others, in order:
    ///
    /// 4. Included files over 100 MB that Git LFS doesn't track
    ///    (`commitOversizedFiles`).
    /// 5. Included conflicted files that still have conflict markers (or
    ///    are binary or deleted on one side), `commitConflictMarkers`.
    func checkFileGates(
        _ files: [WorkingDirectoryFileChange],
        in repository: RepositoryModel,
        confirmed: Set<ConfirmationKind>
    ) async throws(OperationError) {
        if !confirmed.contains(.commitOversizedFiles) {
            let gitRepository = repository.gitRepository
            let oversized = await repository.environment.withRuntimes {
                await oversizedFilesNotTrackedByLFS(files, in: gitRepository)
            }
            if !oversized.isEmpty {
                throw OperationError(
                    .confirmationRequired(.commitOversizedFiles(oversized)),
                    operation: .commit,
                    repositoryID: repository.id,
                    gitContext: .commit
                )
            }
        }

        if !confirmed.contains(.commitConflictMarkers) {
            // which of the files selected for committing are conflicted (with markers)?
            let conflicted = files.filter { file in
                guard case .conflicted(let status) = file.status else {
                    return false
                }
                return hasUnresolvedConflicts(status)
            }
            if !conflicted.isEmpty {
                throw OperationError(
                    .confirmationRequired(.commitConflictMarkers(conflicted.map(\.path))),
                    operation: .commit,
                    repositoryID: repository.id,
                    gitContext: .commit
                )
            }
        }
    }

    /// `Co-Authored-By` trailers for the known co-authors, in GitHub
    /// repositories (the only ones with the field).
    func coAuthorTrailers(in repository: RepositoryModel) -> [Trailer] {
        guard draft.showCoAuthoredBy, repository.record.gitHubRepository != nil else {
            return []
        }
        return draft.coAuthors.compactMap { author in
            if case .known(let known) = author {
                Trailer(token: "Co-Authored-By", value: "\(known.name) <\(known.email)>")
            } else {
                nil
            }
        }
    }

    /// The summary filled in for a single file.
    func placeholderSummary(for file: WorkingDirectoryFileChange) -> String {
        let fileName = POSIXPath.basename(file.path)
        switch file.status.kind {
        case .new, .untracked:
            return "Create \(fileName)"
        case .deleted:
            return "Delete \(fileName)"
        default:
            // this doesn't feel like a great message for AppFileStatus.Copied or
            // AppFileStatus.Renamed but without more insight (and whether this
            // affects other parts of the flow) we can just default to this for now
            return "Update \(fileName)"
        }
    }

    /// The summary placeholder for the files the next commit includes:
    /// "Create/Update/Delete <file>" for one file, else nil (never in tutorial
    /// repositories).
    public var summaryPlaceholder: String? {
        guard let repository, !repository.record.isTutorialRepository else {
            return nil
        }
        let files = repository.changes.workingDirectory.files.filter(\.isIncludedInCommit)
        return files.count == 1 ? placeholderSummary(for: files[0]) : nil
    }
}

/// The included files over GitHub's 100 MB limit that Git LFS doesn't
/// track. A file whose size can't be read is skipped; a failure asking Git
/// LFS counts the files as untracked.
@concurrent
func oversizedFilesNotTrackedByLFS(_ files: [WorkingDirectoryFileChange], in repository: Repository) async -> [String] {
    var oversized: [String] = []
    for file in files where file.selection.getSelectionType() != .none {
        let path = POSIXPath.join(repository.path, file.path)
        // `stat`, which follows symbolic links.
        var info = stat()
        guard stat(path, &info) == 0 else {
            logger.debug("Unable to get the file size for \(file.path, privacy: .private)")
            continue
        }
        if info.st_size > off_t(largeFileLimit) {
            oversized.append(file.path)
        }
    }
    guard !oversized.isEmpty else {
        return []
    }
    do {
        return try await filesNotTrackedByLFS(repository, oversized)
    } catch {
        logger.error("Could not check which large files Git LFS tracks: \(error.localizedDescription, privacy: .public)")
        return oversized
    }
}

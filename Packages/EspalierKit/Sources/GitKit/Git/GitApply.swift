// Ported from desktop/app/src/lib/git/apply.ts

import EspalierSupport

public func applyPatchToIndex(_ repository: Repository, _ file: WorkingDirectoryFileChange) async throws {
    // If the file was a rename we have to recreate that rename since we've
    // just blown away the index. Think of this block of weird looking commands
    // as running `git mv`.
    if case .renamed(let oldPath, _, _) = file.status {
        // Make sure the index knows of the removed file. We could use
        // update-index --force-remove here but we're not since it's
        // possible that someone staged a rename and then recreated the
        // original file and we don't have any guarantees for in which order
        // partial stages vs full-file stages happen. By using git add the
        // worst that could happen is that we re-stage a file already staged
        // by updateIndex.
        //
        // The old path is a literal pathspec here and below; as a pattern,
        // `add --update` would also stage the changes of the files it
        // matched.
        try await git(
            ["add", "--update", "--", literalPathspec(oldPath)],
            repository.path,
            "applyPatchToIndex"
        )

        // Figure out the blob oid of the removed file
        // <mode> SP <type> SP <object> TAB <file>
        let oldFile = try await git(
            ["ls-tree", "HEAD", "--", literalPathspec(oldPath)],
            repository.path,
            "applyPatchToIndex"
        )

        // A missing field becomes an empty argument, which makes
        // `update-index` fail.
        let info = JSCompat.split(oldFile.stdout, "\t")[0]
        let fields = JSCompat.split(info, " ")
        let mode = fields[0]
        let oid = fields.count > 2 ? fields[2] : ""

        // Add the old file blob to the index under the new name
        try await git(
            ["update-index", "--add", "--cacheinfo", mode, oid, file.path],
            repository.path,
            "applyPatchToIndex"
        )
    }

    let applyArgs = [
        "apply",
        "--cached",
        "--unidiff-zero",
        "--whitespace=nowarn",
        "-",
    ]

    // Without textconv, so the patch carries the file's own text rather
    // than a diff driver's converted text, which `git apply` would commit
    // for a new file.
    if await isTextConverted(repository, file.path) {
        throw GitLibError(textConvertedMessage(file.path, "committed"))
    }
    let diff = try await getWorkingDirectoryDiff(repository, file, textConv: false)

    let patch: String
    switch diff {
    case .text(let textDiff):
        patch = try formatPatch(file, textDiff)
    case .largeText(let largeTextDiff):
        patch = try formatPatch(file, largeTextDiff)
    case .binary, .submodule, .image:
        throw GitLibError("Can't create partial commit in binary file: \(file.path)")
    case .unrenderable:
        throw GitLibError("File diff is too large to generate a partial commit: \(file.path)")
    }

    try await git(applyArgs, repository.path, "applyPatchToIndex", options: GitExecutionOptions(stdin: patch))
}

/// Discards the local changes for the specified file based on the passed diff
/// and a selection of lines from it.
///
/// When passed an empty selection, this method won't do anything. When passed a
/// full selection, all changes from the file will be discarded.
///
/// - Parameters:
///   - repository: The repository in which to update the working directory
///     with information from the index
///   - filePath: The relative path in the working directory of the file to use
///   - diff: The diff containing the file local changes
///   - selection: The selection of changes from the diff to discard
public func discardChangesFromSelection(
    _ repository: Repository,
    _ filePath: String,
    _ diff: some TextDiffData,
    _ selection: DiffSelection
) async throws {
    // A file whose diff isn't UTF-8 can't be written back line by line (see
    // `isByteExact`).
    guard isByteExact(diff) else {
        throw GitLibError(notByteExactMessage(filePath, "discarded"))
    }
    guard let patch = formatPatchToDiscardChanges(filePath, diff, selection) else {
        // When the patch is null we don't need to apply it since it will be a noop.
        return
    }

    let args = ["apply", "--unidiff-zero", "--whitespace=nowarn", "-"]

    try await git(args, repository.path, "discardChangesFromSelection", options: GitExecutionOptions(stdin: patch))
}

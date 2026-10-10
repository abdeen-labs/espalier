// Ported from dugite/test/fast/git-process-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git-process")
struct DugiteGitProcessFastTests {
    @Test("can cancel in-progress git command")
    func canCancelInProgressGitCommand() async throws {
        // Cancelling the calling task stops git, and `Dugite.exec` throws
        // `CancellationError`.
        //
        // git's stdin is /dev/null when no input is given, so git-hash-object
        // wouldn't wait for it; instead the task is cancelled as soon as git
        // has spawned.
        TestEnvironment.bootstrap()
        let task = Task {
            try await Dugite.exec(
                ["hash-object", "--stdin"],
                FileManager.default.currentDirectoryPath,
                options: Dugite.ExecutionOptions(processCallback: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Suite("exitCode")
    struct ExitCode {
        @Test("handles stdin closed errors")
        func handlesStdinClosedErrors() async throws {
            let testRepoPath = try createTestDir("desktop-git-test-blank")

            // Pass an unknown arg to Git, forcing it to terminate immediately
            // and then try to write to stdin, which fails with EPIPE unless the
            // closed input stream is ignored.
            let result = try await Dugite.exec(["--trololol"], testRepoPath, options: Dugite.ExecutionOptions(
                stdin: Data(String(repeating: "\n", count: 1024 * 1024).utf8)
            ))
            try verify(result) { r in
                try #require(r.exitCode == 129)
            }
        }

        @Suite("show")
        struct Show {
            @Test("missing from index")
            func missingFromIndex() async throws {
                let testRepoPath = try await initialize("desktop-show-missing-index")

                let result = try await Dugite.exec(["show", ":missing.txt"], testRepoPath)

                assertHasGitError(result, .pathDoesNotExist)
            }

            @Test("missing from commitish")
            func missingFromCommitish() async throws {
                let testRepoPath = try await initialize("desktop-show-missing-commitish")

                let filePath = POSIXPath.join(testRepoPath, "file.txt")

                try "some content".write(toFile: filePath, atomically: false, encoding: .utf8)

                _ = try await Dugite.exec(["add", "."], testRepoPath)
                _ = try await Dugite.exec(["commit", "-m", "\"added a file\""], testRepoPath)

                let result = try await Dugite.exec(["show", "HEAD:missing.txt"], testRepoPath)

                assertHasGitError(result, .pathDoesNotExist)
            }

            @Test("invalid object name - empty repository")
            func invalidObjectNameEmptyRepository() async throws {
                let testRepoPath = try await initialize("desktop-show-invalid-object-empty")

                let result = try await Dugite.exec(["show", "HEAD:missing.txt"], testRepoPath)

                assertHasGitError(result, .invalidObjectName)
            }

            @Test("outside repository")
            func outsideRepository() async throws {
                let testRepoPath = try await initialize("desktop-show-outside")

                let filePath = POSIXPath.join(testRepoPath, "file.txt")

                try "some content".write(toFile: filePath, atomically: false, encoding: .utf8)

                _ = try await Dugite.exec(["add", "."], testRepoPath)
                _ = try await Dugite.exec(["commit", "-m", "\"added a file\""], testRepoPath)

                let result = try await Dugite.exec(["show", "--", "/missing.txt"], testRepoPath)

                assertHasGitError(result, .outsideRepository)
            }
        }
    }

    @Suite("errors")
    struct Errors {
        @Test("raises error when folder does not exist")
        func raisesErrorWhenFolderDoesNotExist() async throws {
            TestEnvironment.bootstrap()
            let randomHex = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
            let testRepoPath = POSIXPath.join(NSTemporaryDirectory(), "desktop-does-not-exist-" + randomHex)

            let error = await #expect(throws: ExecError.self) {
                try await Dugite.exec(["show", "HEAD"], testRepoPath)
            }

            #expect(error?.message.contains("Git failed to execute.") == true)
            #expect(error?.code == "ENOENT")
        }

        @Test("parses git's error output", arguments: parseErrorCases)
        func parsesErrorOutput(_ testCase: NamedCase<(output: String, expected: DugiteError)>) {
            #expect(Dugite.parseError(testCase.value.output) == testCase.value.expected)
        }

        static let parseErrorCases: [NamedCase<(output: String, expected: DugiteError)>] = [
            NamedCase("can parse HTTPS auth errors", (output: "fatal: Authentication failed for 'https://www.github.com/shiftkey/desktop.git/'", expected: .httpsAuthenticationFailed)),
            NamedCase("can parse SSH auth errors", (output: "fatal: Authentication failed", expected: .sshAuthenticationFailed)),
            NamedCase("can parse bad revision errors", (output: "fatal: bad revision 'beta..origin/beta'", expected: .badRevision)),
            NamedCase("can parse unrelated histories error", (output: "fatal: refusing to merge unrelated histories", expected: .cannotMergeUnrelatedHistories)),
            NamedCase("can parse GH001 push file size error", (output: """
                remote: error: GH001: Large files detected. You may want to try Git Large File Storage - https://git-lfs.github.com.
                remote: error: Trace: 2bd2bfca1605d4e0847936332f1b6c07
                remote: error: See http://git.io/iEPt8g for more information.
                remote: error: File some-file.mp4 is 292.85 MB; this exceeds GitHub's file size limit of 100.00 MB
                To https://github.com/shiftkey/too-large-repository.git
                 ! [remote rejected] master -> master (pre-receive hook declined)
                error: failed to push some refs to 'https://github.com/shiftkey/too-large-repository.git'
                """, expected: .pushWithFileSizeExceedingLimit)),
            NamedCase("can parse GH002 branch name error", (output: """
                remote: error: GH002: Sorry, branch or tag names consisting of 40 hex characters are not allowed.
                remote: error: Invalid branch or tag name "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                To https://github.com/shiftkey/too-large-repository.git
                 ! [remote rejected] aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (pre-receive hook declined)
                error: failed to push some refs to 'https://github.com/shiftkey/too-large-repository.git'
                """, expected: .hexBranchNameRejected)),
            NamedCase("can parse GH003 force push error", (output: """
                remote: error: GH003: Sorry, force-pushing to my-cool-branch is not allowed.
                To https://github.com/shiftkey/too-large-repository.git
                 ! [remote rejected]  my-cool-branch ->  my-cool-branch (pre-receive hook declined)
                error: failed to push some refs to 'https://github.com/shiftkey/too-large-repository.git'
                """, expected: .forcePushRejected)),
            // there's probably some output here missing but I couldn't trigger this locally
            NamedCase("can parse GH005 ref length error", (output: """
                remote: error: GH005: Sorry, refs longer than 255 bytes are not allowed.
                To https://github.com/shiftkey/too-large-repository.git
                ...
                """, expected: .invalidRefLength)),
            NamedCase("can parse GH006 protected branch push error", (output: """
                remote: error: GH006: Protected branch update failed for refs/heads/master.
                remote: error: At least one approved review is required
                To https://github.com/shiftkey-tester/protected-branches.git
                 ! [remote rejected] master -> master (protected branch hook declined)
                error: failed to push some refs to 'https://github.com/shiftkey-tester/protected-branches.git'
                """, expected: .protectedBranchRequiresReview)),
            NamedCase("can parse GH006 protected branch force push error", (output: """
                remote: error: GH006: Protected branch update failed for refs/heads/master.
                remote: error: Cannot force-push to a protected branch
                To https://github.com/shiftkey/too-large-repository.git
                 ! [remote rejected] master -> master (protected branch hook declined)
                error: failed to push some refs to 'https://github.com/shiftkey/too-large-repository.git'
                """, expected: .protectedBranchForcePush)),
            NamedCase("can parse GH006 protected branch delete error", (output: """
                remote: error: GH006: Protected branch update failed for refs/heads/dupe.
                remote: error: Cannot delete a protected branch
                To https://github.com/tierninho-tester/trterdgdfgdf.git
                  ! [remote rejected] dupe (protected branch hook declined)
                error: failed to push some refs to 'https://github.com/tierninho-tester/trterdgdfgdf.git'
                """, expected: .protectedBranchDeleteRejected)),
            NamedCase("can parse GH006 required status check error", (output: """
                remote: error: GH006: Protected branch update failed for refs/heads/master.
                remote: error: Required status check "continuous-integration/travis-ci" is expected.
                To https://github.com/Raul6469/EclipseMaven.git
                  ! [remote rejected] master -> master (protected branch hook declined)
                error: failed to push some refs to 'https://github.com/Raul6469/EclipseMaven.git
                """, expected: .protectedBranchRequiredStatus)),
            NamedCase("can parse GH007 push with private email error", (output: """
                remote: error: GH007: Your push would publish a private email address.
                remote: You can make your email public or disable this protection by visiting:
                remote: http://github.com/settings/emails
                """, expected: .pushWithPrivateEmail)),
            NamedCase("can parse LFS attribute does not match error", (output: #"The filter.lfs.clean attribute should be "git-lfs clean -- %f" but is "git lfs clean %f""#, expected: .lfsAttributeDoesNotMatch)),
            // What the bundled Git LFS 3.7.1 prints, on standard output, for
            // `git lfs install --skip-repo`: "the", not "The".
            NamedCase("can parse Git LFS 3's attribute does not match warning", (output: """
                warning: the "filter.lfs.clean" attribute should be "git-lfs clean -- %f" but is "git-lfs clean --other -- %f"
                Run `git lfs install --force` to reset Git configuration.

                """, expected: .lfsAttributeDoesNotMatch)),
            NamedCase("can parse rename Branch error", (output: """
                error: refname refs/heads/adding-renamefailed-error not found
                      fatal: Branch rename failed
                """, expected: .branchRenameFailed)),
            NamedCase("can parse path does not exist error - neither on disk nor in the index", (output: "fatal: path 'missing.txt' does not exist (neither on disk nor in the index).\n", expected: .pathDoesNotExist)),
            NamedCase("can parse path does not exist error - in commitish", (output: "fatal: path 'missing.txt' does not exist in 'HEAD'\n", expected: .pathDoesNotExist)),
            NamedCase("can parse invalid object name error", (output: "fatal: invalid object name 'HEAD'.\n", expected: .invalidObjectName)),
            NamedCase("can parse is outside repository error", (output: "fatal: /missing.txt: '/missing.txt' is outside repository\n", expected: .outsideRepository)),
            NamedCase("can parse lock file exists error", (output: """
                Unable to create  'path_to_repo/.git/index.lock: File exists.

                Another git process seems to be running in this repository, e.g.
                an editor opened by 'git commit'. Please make sure all processes
                are terminated then try again. If it still fails, a git process
                may have crashed in this repository earlier:
                remove the file manually to continue.
                """, expected: .lockFileAlreadyExists)),
            NamedCase("can parse the previous not found repository error", (output: "fatal: Not a git repository (or any of the parent directories): .git", expected: .notAGitRepository)),
            NamedCase("can parse the current found repository error", (output: "fatal: not a git repository (or any of the parent directories): .git", expected: .notAGitRepository)),
            NamedCase("can parse the no merge to abort error", (output: "fatal: There is no merge to abort (MERGE_HEAD missing).\n", expected: .noMergeToAbort)),
            NamedCase("can parse the pulling non-existent remote branch error", (output: "Your configuration specifies to merge with the ref 'refs/heads/tierninho-patch-1'\nfrom the remote, but no such ref was fetched.\n", expected: .noExistingRemoteBranch)),
            NamedCase("can parse the local files overwritten error", (output: "error: Your local changes to the following files would be overwritten by checkout:\n", expected: .localChangesOverwritten)),
            NamedCase("can parse the local files overwritten error", (output: "error: The following untracked working tree files would be overwritten by checkout:\n", expected: .localChangesOverwritten)),
            NamedCase("can parse the unresovled conflicts error", (output: """
                2-simple-rebase-conflict/LICENSE.md: needs merge
                You must edit all merge conflicts and then
                mark them as resolved using git add
                """, expected: .unresolvedConflicts)),
            NamedCase("can parse the failed to sign data error within a rebase", (output: """
                Rebasing (1/4)
                      Rebasing (2/4)
                      error: gpg failed to sign the data
                """, expected: .gpgFailedToSignData)),
            NamedCase("can parse the could not resolve host error", (output: "\"Cloning into '/cloneablepath/'...\nfatal: unable to access 'https://github.com/Daniel-McCarthy/dugite.git/': Could not resolve host: github.com\n\"", expected: .hostDown)),
            NamedCase("can parse conflict modify delete error", (output: "CONFLICT (modify/delete): a/path/to/a/file.md deleted in HEAD and modified in 1234567 (A commit message). Version 1234567 (A commit message) of a/path/to/a/file.md left in tree.", expected: .conflictModifyDeletedInBranch)),
            NamedCase("can parse path exists but not in ref", (output: "fatal: path 'README.md' exists on disk, but not in '4b825dc642cb6eb9a060e54bf8d69288fbee4904'", expected: .pathExistsButNotInRef)),
            NamedCase("can parse github remote secret detected on push error", (output: Self.secretDetectedOnPush, expected: .pushWithSecretDetected)),
        ]

        /// The push's output, line by line. Lines that git's remote padded with
        /// trailing spaces keep them.
        static let secretDetectedOnPush = [
            "Enumerating objects: 8, done.",
            "Counting objects:  12% (1/8)",
            "Counting objects:  25% (2/8)",
            "Counting objects:  37% (3/8)",
            "Counting objects:  50% (4/8)",
            "Counting objects:  62% (5/8)",
            "Counting objects:  75% (6/8)",
            "Counting objects:  87% (7/8)",
            "Counting objects: 100% (8/8)",
            "Counting objects: 100% (8/8), done.",
            "Delta compression using up to 10 threads",
            "Compressing objects:  25% (1/4)",
            "Compressing objects:  50% (2/4)",
            "Compressing objects:  75% (3/4)",
            "Compressing objects: 100% (4/4)",
            "Compressing objects: 100% (4/4), done.",
            "Writing objects:  16% (1/6)",
            "Writing objects:  33% (2/6)",
            "Writing objects:  50% (3/6)",
            "Writing objects:  66% (4/6)",
            "Writing objects:  83% (5/6)",
            "Writing objects: 100% (6/6)",
            "Writing objects: 100% (6/6), 618 bytes | 618.00 KiB/s, done.",
            "Total 6 (delta 1), reused 0 (delta 0), pack-reused 0 (from 0)",
            "remote: Resolving deltas:   0% (0/1)        ",
            "remote: Resolving deltas: 100% (1/1)        ",
            "remote: Resolving deltas: 100% (1/1), done.        ",
            "remote: error: GH013: Repository rule violations found for refs/heads/main.        ",
            "remote: ",
            "remote: - GITHUB PUSH PROTECTION        ",
            "remote:   —————————————————————————————————————————        ",
            "remote:     Resolve the following violations before pushing again        ",
            "remote: ",
            "remote:     - Push cannot contain secrets        ",
            "remote: ",
            "remote:             ",
            "remote:      (?) Learn how to resolve a blocked push        ",
            "remote:      https://docs.github.com/code-security/secret-scanning/working-with-secret-scanning-and-push-protection/working-with-push-protection-from-the-command-line#resolving-a-blocked-push        ",
            "remote:             ",
            "remote:             ",
            "remote:       —— GitHub Personal Access Token ——————————————————————        ",
            "remote:        locations:        ",
            "remote:          - commit: a6cf64dbe7fcefb6d90238a8d13d831db5dec3e9        ",
            "remote:            path: README.md:4        ",
            "remote:          - commit: 34800b208dd1432b6d7bff2789e09a3c89ab037d        ",
            "remote:            path: README.md:4        ",
            "remote:          - commit: a6cf64dbe7fcefb6d90238a8d13d831db5dec3e9        ",
            "remote:            path: README.md:5        ",
            "remote:          - commit: a6cf64dbe7fcefb6d90238a8d13d831db5dec3e9        ",
            "remote:            path: README.md:6        ",
            "remote:             ",
            "remote:        (?) To push, remove secret from commit(s) or follow this URL to allow the secret.        ",
            "remote:        https://github.com/tidy-dev/public_playground/security/secret-scanning/unblock-secret/2w2db5WJQCitzO0A2UDh0yyB3Ob        ",
            "remote:             ",
            "remote: ",
            "remote: ",
            "To https://github.com/tidy-dev/public_playground.git",
            " ! [remote rejected] main -> main (push declined due to repository rule violations)",
            "error: failed to push some refs to 'https://github.com/tidy-dev/public_playground.git'",
            "",
        ].joined(separator: "\n")

        @Test("can parse an error when merging or rebasing with local changes", arguments: [
            NamedCase("can parse an error when merging with local changes", (command: "merge", expected: DugiteError.mergeWithLocalChanges)),
            NamedCase("can parse an error when renasing with local changes", (command: "rebase", expected: .rebaseWithLocalChanges)),
        ])
        func withLocalChanges(_ testCase: NamedCase<(command: String, expected: DugiteError)>) async throws {
            let repoPath = try await initialize("desktop-merge-with-local-changes")
            let readmePath = POSIXPath.join(repoPath, "Readme.md")

            // Add a commit to the default branch.
            try "# README".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"added README\""], repoPath)

            // Create another branch and add commit.
            _ = try await Dugite.exec(["checkout", "-b", "some-other-branch"], repoPath)
            try "# README modified in branch".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"updated README\""], repoPath)

            // Go back to the default branch and modify a file.
            _ = try await Dugite.exec(["checkout", "-"], repoPath)
            try "# README modified in master".write(toFile: readmePath, atomically: false, encoding: .utf8)

            // Execute a merge or a rebase.
            let result = try await Dugite.exec([testCase.value.command, "some-other-branch"], repoPath)

            assertHasGitError(result, testCase.value.expected)
        }

        @Test("can parse an error when pulling with local changes", arguments: [
            NamedCase("can parse an error when pulling with merge with local changes", (pullRebase: "false", expected: DugiteError.mergeWithLocalChanges)),
            NamedCase("can parse an error when pulling with rebase with local changes", (pullRebase: "true", expected: .rebaseWithLocalChanges)),
        ])
        func pullingWithLocalChanges(_ testCase: NamedCase<(pullRebase: String, expected: DugiteError)>) async throws {
            let (repoPath, remoteRepositoryPath) = try await initializeWithRemote(
                "desktop-pullrebase-with-local-changes",
                nil
            )
            let (forkRepoPath, _) = try await initializeWithRemote(
                "desktop-pullrebase-with-local-changes-fork",
                remoteRepositoryPath
            )
            _ = try await Dugite.exec(["config", "pull.rebase", testCase.value.pullRebase], forkRepoPath)
            let readmePath = POSIXPath.join(repoPath, "Readme.md")
            let readmePathInFork = POSIXPath.join(forkRepoPath, "Readme.md")

            // Add a commit to the default branch.
            try "# README".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"added README\""], repoPath)

            // Push the commit and fetch it from the fork.
            _ = try await Dugite.exec(["push", "origin", "HEAD", "-u"], repoPath)
            _ = try await Dugite.exec(["pull", "origin", "HEAD"], forkRepoPath)

            // Add another commit and push it
            try "# README modified from upstream".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"updated README\""], repoPath)
            _ = try await Dugite.exec(["push", "origin"], repoPath)

            // Modify locally the Readme file in the fork.
            try "# README modified from fork".write(toFile: readmePathInFork, atomically: false, encoding: .utf8)

            // Pull from the fork
            let result = try await Dugite.exec(["pull", "origin", "HEAD"], forkRepoPath)

            assertHasGitError(result, testCase.value.expected)
        }

        @Test("can parse an error when there is a conflict while merging or rebasing", arguments: [
            NamedCase("can parse an error when there is a conflict while merging", (command: "merge", expected: DugiteError.mergeConflicts)),
            NamedCase("can parse an error when there is a conflict while rebasing", (command: "rebase", expected: .rebaseConflicts)),
        ])
        func conflicts(_ testCase: NamedCase<(command: String, expected: DugiteError)>) async throws {
            let repoPath = try await initialize("desktop-pullrebase-with-local-changes")
            let readmePath = POSIXPath.join(repoPath, "Readme.md")

            // Create a commit on the default branch.
            try "# README".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"initial commit\""], repoPath)

            // Create a branch and add another commit.
            _ = try await Dugite.exec(["checkout", "-b", "my-branch"], repoPath)
            try "# README from my-branch".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"modify README in my-branch\""], repoPath)

            // Go back to the default branch and add a commit that conflicts.
            _ = try await Dugite.exec(["checkout", "-"], repoPath)
            try "# README from default".write(toFile: readmePath, atomically: false, encoding: .utf8)
            _ = try await Dugite.exec(["add", "."], repoPath)
            _ = try await Dugite.exec(["commit", "-m", "\"modifiy README in default branch\""], repoPath)

            // Try to merge or rebase onto the branch.
            let result = try await Dugite.exec([testCase.value.command, "my-branch"], repoPath)

            assertHasGitError(result, testCase.value.expected)
        }
    }
}

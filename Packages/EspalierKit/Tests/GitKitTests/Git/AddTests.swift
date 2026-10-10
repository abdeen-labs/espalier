// Ported from desktop/app/test/unit/git/add-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/add")
struct AddTests {
    @Suite("addConflictedFile")
    struct AddConflictedFile {
        @Test("stages a conflicted file after manual resolution")
        func stagesAfterManualResolution() async throws {
            let repo = try await setupConflictedRepo()

            // Get the conflicted status
            let beforeStatus = try await getStatusOrThrow(repo)
            let conflictedFiles = beforeStatus.workingDirectory.files.filter { $0.status.kind == .conflicted }
            #expect(conflictedFiles.count > 0, "Expected at least one conflicted file")

            let file = try #require(conflictedFiles.first)

            // Resolve the conflict by writing new content
            try Data("resolved content\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, file.path)))

            // Stage the resolved file
            try await addConflictedFile(repo, file)

            // Verify the file is no longer conflicted in status
            let afterStatus = try await getStatusOrThrow(repo)
            let stillConflicted = afterStatus.workingDirectory.files.filter {
                $0.path == file.path && $0.status.kind == .conflicted
            }
            #expect(stillConflicted.count == 0, "File should no longer be conflicted after staging")
        }
    }
}

// The other ways a conflict is staged as resolved: through rm, checkout,
// and add.
@Suite("git/stage stageManualConflictResolution")
struct StageManualConflictResolutionTests {
    private func conflictedFile(_ repo: Repository, _ path: String) async throws -> WorkingDirectoryFileChange {
        let status = try await getStatusOrThrow(repo)
        return try #require(status.workingDirectory.files.first { $0.path == path && $0.status.kind == .conflicted })
    }

    private func readFile(_ repo: Repository, _ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(filePath: POSIXPath.join(repo.path, path))), as: UTF8.self)
    }

    @Test("uses our or their side of a modified file")
    func modifiedFile() async throws {
        let ours = try await setupConflictedRepoWithMultipleFiles()
        // A binary-like resolution of a text conflict: still has markers, so
        // it's resolved with the chosen side.
        try await stageManualConflictResolution(ours, try await conflictedFile(ours, "foo"), .ours)
        #expect(try readFile(ours, "foo") == "b2")

        let theirs = try await setupConflictedRepoWithMultipleFiles()
        try await stageManualConflictResolution(theirs, try await conflictedFile(theirs, "foo"), .theirs)
        #expect(try readFile(theirs, "foo") == "b1")

        let status = try await getStatusOrThrow(theirs)
        #expect(status.workingDirectory.files.first { $0.path == "foo" }?.status.kind == .modified)
    }

    @Test("deletes or keeps a file deleted on one side")
    func deletedFile() async throws {
        // "bar" was deleted by them (master) and modified by us.
        let theirs = try await setupConflictedRepoWithMultipleFiles()
        try await stageManualConflictResolution(theirs, try await conflictedFile(theirs, "bar"), .theirs)
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(theirs.path, "bar")))
        let afterTheirs = try await getStatusOrThrow(theirs)
        #expect(afterTheirs.workingDirectory.files.first { $0.path == "bar" }?.status.kind == .deleted)

        let ours = try await setupConflictedRepoWithMultipleFiles()
        try await stageManualConflictResolution(ours, try await conflictedFile(ours, "bar"), .ours)
        #expect(try readFile(ours, "bar") == "b2")
        let afterOurs = try await getStatusOrThrow(ours)
        #expect(afterOurs.workingDirectory.files.first { $0.path == "bar" } == nil)
    }

    @Test("leaves a file whose markers were already resolved, and an unconflicted file, alone")
    func noOps() async throws {
        let repo = try await setupConflictedRepoWithMultipleFiles()
        try Data("b1b2".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "foo")))
        let resolved = try await conflictedFile(repo, "foo")
        try await stageManualConflictResolution(repo, resolved, .theirs)
        #expect(try readFile(repo, "foo") == "b1b2")
        #expect(try await conflictedFile(repo, "foo").status.kind == .conflicted)

        let untracked = try #require(try await getStatusOrThrow(repo).workingDirectory.files.first { $0.path == "dog" })
        try await stageManualConflictResolution(repo, untracked, .ours)
        #expect(try readFile(repo, "dog") == "touch")
        let after = try await getStatusOrThrow(repo)
        #expect(after.workingDirectory.files.first { $0.path == "dog" }?.status.kind == .untracked)
    }
}

// `unstageAllFiles`.
@Suite("git/rm")
struct RmTests {
    @Test("removes all files from the index")
    func unstagesAll() async throws {
        let repo = try await setupTwoCommitRepo()
        try await unstageAllFiles(repo)
        let status = try await getStatusOrThrow(repo)
        // Each staged deletion is replaced by the untracked file at its path.
        #expect(status.workingDirectory.files.map(\.path) == ["good-file", "great-file"])
        #expect(status.workingDirectory.files.map(\.status.kind) == [.untracked, .untracked])
    }
}

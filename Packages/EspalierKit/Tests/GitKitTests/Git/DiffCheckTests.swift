// Ported from desktop/app/test/unit/git/diff-check-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("getFilesWithConflictMarkers")
struct DiffCheckTests {
    @Suite("with one conflicted file")
    struct WithMultipleConflictedFiles {
        @Test("finds multiple conflicted files")
        func findsMultiple() async throws {
            let repository = try await setupConflictedRepoWithMultipleFiles()
            #expect(try await getFilesWithConflictMarkers(repository.path) == [
                "baz": 3,
                "cat": 3,
                "foo": 3,
            ])
        }
    }

    @Suite("with no conflicted files")
    struct WithNoConflictedFiles {
        @Test("finds no conflicted files")
        func findsNone() async throws {
            let repository = try setupEmptyRepository()
            #expect(try await getFilesWithConflictMarkers(repository.path).count == 0)
        }
    }

    @Test("counts markers in paths with colons and digits, and ignores whitespace errors")
    func unusualPaths() async throws {
        let repository = try setupEmptyRepository()
        let path = "a:1: b.txt"
        try await makeCommit(repository, Tree(entries: [
            TreeEntry(path: path, contents: "one\n"),
            TreeEntry(path: "spaces.txt", contents: "x\n"),
        ]))
        try Data("<<<<<<< ours\none\n=======\ntwo\n>>>>>>> theirs\n".utf8)
            .write(to: URL(filePath: repository.path + "/" + path))
        try Data("x \n".utf8).write(to: URL(filePath: repository.path + "/spaces.txt"))

        #expect(try await getFilesWithConflictMarkers(repository.path) == [path: 3])
    }
}

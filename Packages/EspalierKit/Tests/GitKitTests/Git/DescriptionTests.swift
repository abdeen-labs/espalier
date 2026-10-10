// Ported from desktop/app/test/unit/git/description-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/description")
struct DescriptionTests {
    @Suite("getGitDescription")
    struct GetGitDescription {
        @Test("returns empty for an initialized repository")
        func emptyForInitializedRepository() async throws {
            let repo = try setupEmptyRepository()
            let actual = await getGitDescription(repo.path)
            #expect(actual == "")
        }

        @Test("returns empty when path is missing")
        func emptyWhenPathIsMissing() async throws {
            let repo = try setupEmptyRepository()
            let path = POSIXPath.join(repo.path, ".git", "description")
            try FileManager.default.removeItem(atPath: path)

            let actual = await getGitDescription(repo.path)
            #expect(actual == "")
        }

        @Test("reads the custom text")
        func readsCustomText() async throws {
            let expected = "this is a repository description"
            let repo = try setupEmptyRepository()
            let path = POSIXPath.join(repo.path, ".git", "description")
            try Data(expected.utf8).write(to: URL(filePath: path))

            let actual = await getGitDescription(repo.path)
            #expect(actual == expected)
        }
    }
}

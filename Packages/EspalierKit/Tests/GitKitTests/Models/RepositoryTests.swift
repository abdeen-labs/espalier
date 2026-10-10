// Ported from desktop/app/test/unit/repository-test.ts

import GitKit
import Testing

@Suite("Repository")
struct RepositoryTests {
    @Suite("name")
    struct Name {
        @Test("uses the last path component as the name")
        func usesTheLastPathComponentAsTheName() {
            let repoPath = "/some/cool/path"
            let repository = Repository(path: repoPath)
            #expect(repository.name == "path")
        }

        @Test("handles repository at root of the drive")
        func handlesRepositoryAtRootOfTheDrive() {
            // The root of a volume, whose basename is empty.
            let repoPath = "/"
            let repository = Repository(path: repoPath)
            #expect(repository.name == "/")
        }
    }
}

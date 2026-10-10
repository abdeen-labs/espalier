// Ported from desktop/app/test/unit/cloning-repository-test.ts
//
// `CloneTask` is a clone in progress, named after its URL, identified by a
// `CloneID`.

import EspalierCore
import Testing

@Suite("CloningRepository")
struct CloningRepositoryTests {
    @Suite("name")
    struct Name {
        @Test("extracts the repo name from the url not the path")
        func nameFromURL() {
            let repository = CloneTask(url: "https://github.com/desktop/desktop", path: "C:/some/path/to/repo")

            #expect(repository.name == "desktop")
        }

        @Test("extracts the repo name without git suffix")
        func nameWithoutGitSuffix() {
            let repository = CloneTask(url: "https://github.com/desktop/desktop.git", path: "C:/some/path/to/repo")

            #expect(repository.name == "desktop")
        }
    }

    // MARK: - Espalier

    @Test("names SSH URLs and URLs ending in a slash")
    func otherURLs() {
        #expect(CloneTask(url: "git@github.com:desktop/desktop.git", path: "/tmp/a").name == "desktop")
        #expect(CloneTask(url: "https://github.com/desktop/desktop/", path: "/tmp/a").name == "desktop")
    }
}

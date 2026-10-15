// Case-only renames on macOS's default case-insensitive volume, end to end
// through the models: `git mv a.txt A.txt` committed in Espalier, a rename
// made in Finder, switching between branches whose files differ only in
// case, and branch names that differ only in case. The repositories come
// from `git init`, which sets `core.ignorecase` on such a volume.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: case-only renames", .offline) @MainActor
struct CaseOnlyRenameTests {
    /// The names in the directory, exactly as the file system has them.
    private func namesOnDisk(_ fixture: ChangesFixture) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: fixture.local.path).filter { $0 != ".git" })
    }

    private func isCaseInsensitiveVolume(_ path: String) throws -> Bool {
        let values = try URL(filePath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values.volumeSupportsCaseSensitiveNames == false
    }

    private func makeFixture() async throws -> ChangesFixture {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.gitCommit("readme.txt", "hello\n", message: "Add readme")
        await fixture.refresh(.full)
        return fixture
    }

    @Test("a case-only rename staged with git mv shows as a rename and commits as one")
    func gitMoveCommits() async throws {
        let fixture = try await makeFixture()
        try #require(try isCaseInsensitiveVolume(fixture.local.path))
        #expect(try await fixture.git(["config", "core.ignorecase"]) == "true\n")
        try await fixture.git(["mv", "readme.txt", "README.txt"])
        await fixture.refresh()

        let renamed = try fixture.file("README.txt")
        guard case .renamed(let oldPath, _, _) = renamed.status else {
            Issue.record("Expected a rename, not \(renamed.status)")
            return
        }
        #expect(oldPath == "readme.txt")
        #expect(fixture.paths == ["README.txt"])

        _ = try await fixture.commitIncluded("Capitalize readme")
        #expect(try await fixture.git(["ls-tree", "--name-only", "HEAD"]) == "README.md\nREADME.txt\n")
        #expect(fixture.paths.isEmpty)
        #expect(try namesOnDisk(fixture).contains("README.txt"))
    }

    @Test("a case-only rename made in Finder isn't a change to git, and nothing breaks")
    func finderRename() async throws {
        let fixture = try await makeFixture()
        try #require(try isCaseInsensitiveVolume(fixture.local.path))
        try FileManager.default.moveItem(
            atPath: POSIXPath.join(fixture.local.path, "readme.txt"),
            toPath: POSIXPath.join(fixture.local.path, "Readme.txt")
        )
        #expect(try namesOnDisk(fixture).contains("Readme.txt"))
        await fixture.refresh()
        // With core.ignorecase, git matches the index's name to the file.
        #expect(fixture.paths.isEmpty)

        // An edit shows under the index's name, and commits.
        try fixture.write("Readme.txt", "hello again\n")
        await fixture.refresh()
        #expect(fixture.paths == ["readme.txt"])
        try await fixture.select("readme.txt")
        #expect(addedLines(try fixture.shownText()) == ["hello again"])
        _ = try await fixture.commitIncluded("Edit readme")
        #expect(try await fixture.git(["ls-tree", "--name-only", "HEAD"]) == "README.md\nreadme.txt\n")
        #expect(fixture.paths.isEmpty)
    }

    @Test("switching between branches whose files differ only in case leaves the branch's names on disk and nothing changed")
    func branchesDifferingInCase() async throws {
        let fixture = try await makeFixture()
        try #require(try isCaseInsensitiveVolume(fixture.local.path))
        try await fixture.git(["checkout", "-q", "-b", "capitalized"])
        try await fixture.git(["mv", "readme.txt", "README.txt"])
        try await fixture.git(["commit", "-q", "-m", "Capitalize readme"])
        await fixture.refresh(.full)
        #expect(try namesOnDisk(fixture).contains("README.txt"))

        let main = try fixture.branch("main")
        #expect(try await fixture.model.branches.checkout(main) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(try namesOnDisk(fixture).contains("readme.txt"))
        #expect(!(try namesOnDisk(fixture).contains("README.txt")))

        let capitalized = try fixture.branch("capitalized")
        #expect(try await fixture.model.branches.checkout(capitalized) == .checkedOut(capitalized))
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        #expect(try namesOnDisk(fixture).contains("README.txt"))

        // With a change to the file, the change comes along.
        try fixture.write("README.txt", "changed\n")
        await fixture.refresh()
        #expect(try await fixture.model.branches.checkout(main, strategy: .moveToNewBranch) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(fixture.paths == ["readme.txt"])
        #expect(fixture.read("readme.txt") == "changed\n")
    }

    @Test("a branch whose name differs from another's only in case can't be created; renaming one in case works")
    func branchNamesDifferingInCase() async throws {
        let fixture = try await makeFixture()
        try #require(try isCaseInsensitiveVolume(fixture.local.path))
        _ = try await fixture.model.branches.createBranch("feature", startPoint: nil, checkout: false)
        await fixture.settle()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createBranch("Feature", startPoint: nil, checkout: false)
        }
        #expect(error?.gitFailure?.gitError == .branchAlreadyExists)
        await fixture.settle()
        #expect(fixture.gitState.branches.all.filter { $0.type == .local }.map(\.name).sorted() == ["feature", "main"])

        try await fixture.model.branches.rename(try fixture.branch("feature"), to: "Feature")
        await fixture.settle()
        #expect(fixture.gitState.branches.all.filter { $0.type == .local }.map(\.name).sorted() == ["Feature", "main"])
    }
}

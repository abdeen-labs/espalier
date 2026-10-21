// Changes' per-file line counts ("+10 −2"): the load after each status
// pass, against real git, and its limits.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Line counts", .offline, .hangGuard(minutes: 5)) @MainActor
struct LineCountsLoadTests {
    private func count(_ added: Int, _ deleted: Int) -> FileLineCount {
        FileLineCount(added: added, deleted: deleted)
    }

    @Test("each file's lines added and removed load after a status pass, staged and unstaged together")
    func loadsAfterStatus() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("numbered.txt", numberedLines(10))
        try await fixture.git(["add", "numbered.txt"])
        try await fixture.git(["commit", "-m", "Number the lines"])

        // Staged: line 2 replaced. Unstaged: a line added at the end.
        try fixture.write("numbered.txt", numberedLines(10, replacing: [2: "line two"]))
        try await fixture.git(["add", "numbered.txt"])
        try fixture.write("numbered.txt", numberedLines(10, replacing: [2: "line two"]) + "line 11\n")
        try fixture.write("new.txt", "one\ntwo\nthree")
        try Data([0, 1, 2]).write(to: URL(filePath: POSIXPath.join(fixture.local.path, "image.bin")))
        await fixture.refresh()

        let changes = fixture.changes
        #expect(changes.lineCount(of: try fixture.file("numbered.txt")) == count(2, 1))
        #expect(changes.lineCount(of: try fixture.file("new.txt")) == count(3, 0))
        // A binary file has none.
        #expect(changes.lineCount(of: try fixture.file("image.bin")) == nil)

        // The next pass counts the files again.
        try fixture.write("new.txt", "one\n")
        await fixture.refresh()
        #expect(changes.lineCount(of: try fixture.file("new.txt")) == count(1, 0))
        await fixture.settle()
    }

    @Test("the files show at once; their counts follow when they arrive")
    func filesDoNotWaitForCounts() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let gate = AsyncGate()
        let calls = Mutex(0)
        fixture.changes.countLines = { repository, files, tip in
            calls.withLock { $0 += 1 }
            await gate.wait()
            return try await getWorkingDirectoryLineCounts(repository, files, against: tip)
        }
        try fixture.write("new.txt", "one\ntwo\n")
        await fixture.model.refresh(.status, reason: .user)

        // The status landed without waiting for the counts.
        let file = try fixture.file("new.txt")
        #expect(fixture.changes.lineCount(of: file) == nil)
        #expect(calls.withLock { $0 } == 1)

        gate.open()
        await fixture.changes.lineCountsIdle()
        #expect(fixture.changes.lineCount(of: file) == count(2, 0))
        await fixture.settle()
    }

    @Test("past 1,000 changed files no counts load; a failed load leaves none")
    func limits() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("one.txt", "1\n")
        await fixture.refresh()
        #expect(fixture.changes.lineCounts.count == 1)

        // A load that fails clears what the last pass counted.
        struct CountFailure: Error {}
        fixture.changes.countLines = { _, _, _ in throw CountFailure() }
        try fixture.write("one.txt", "1\n2\n")
        await fixture.refresh()
        #expect(fixture.changes.lineCounts.isEmpty)

        let calls = Mutex(0)
        fixture.changes.countLines = { repository, files, tip in
            calls.withLock { $0 += 1 }
            return try await getWorkingDirectoryLineCounts(repository, files, against: tip)
        }
        await fixture.refresh()
        #expect(calls.withLock { $0 } == 1)
        #expect(fixture.changes.lineCounts.count == 1)

        for index in 1..<ChangesModel.lineCountFileLimit {
            try fixture.write("many/\(index).txt", "\(index)\n")
        }
        await fixture.refresh()
        #expect(fixture.changes.workingDirectory.files.count == ChangesModel.lineCountFileLimit)
        #expect(calls.withLock { $0 } == 2)
        #expect(fixture.changes.lineCounts.count == ChangesModel.lineCountFileLimit)

        try fixture.write("many/one-more.txt", "1\n")
        await fixture.refresh()
        #expect(fixture.changes.workingDirectory.files.count == ChangesModel.lineCountFileLimit + 1)
        #expect(calls.withLock { $0 } == 2)
        #expect(fixture.changes.lineCounts.isEmpty)
        await fixture.settle()
    }

    @Test("a repository that isn't selected loads no counts until it is")
    func onlyWhileSelected() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let (other, _) = try await setupRepositoryWithRemote()
        let otherModel = try await fixture.harness.addAndSelect(other, to: fixture.app)
        fixture.app.select(.repository(fixture.model.id))
        await fixture.settle()

        let calls = Mutex(0)
        otherModel.changes.countLines = { repository, files, tip in
            calls.withLock { $0 += 1 }
            return try await getWorkingDirectoryLineCounts(repository, files, against: tip)
        }
        try fixture.harness.write("new.txt", "one\n", in: other)
        await otherModel.refresh(.status, reason: .user)
        await fixture.settle()
        #expect(otherModel.changes.workingDirectory.files.map(\.path) == ["new.txt"])
        #expect(calls.withLock { $0 } == 0)

        fixture.app.select(.repository(otherModel.id))
        await fixture.app.idle()
        #expect(calls.withLock { $0 } >= 1)
        let file = try #require(otherModel.changes.workingDirectory.files.first)
        #expect(otherModel.changes.lineCount(of: file) == count(1, 0))
        await fixture.settle()
    }
}

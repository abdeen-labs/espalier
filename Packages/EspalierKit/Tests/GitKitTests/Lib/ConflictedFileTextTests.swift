// A conflicted file divided by its markers: conflicts with and without the
// common ancestor's lines, markers of other sizes, marker-like lines on a
// side, stray markers, and keeping one side of a conflict with the rest of
// the file byte for byte (line endings, a missing final newline). Then the
// markers git reports for one file, the `conflict-marker-size` attribute's
// too.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Conflicted file text")
struct ConflictedFileTextTests {
    private func text(_ contents: String, markers: [Int]) -> ConflictedFileText {
        ConflictedFileText(Data(contents.utf8), markerLines: markers)
    }

    @Test("divides a file into the lines outside conflicts and each conflict's sides, the common ancestor's too")
    func divides() throws {
        let file = text(
            "a\n<<<<<<< HEAD\nours1\n=======\ntheirs1\n>>>>>>> feature\nb\n"
                + "<<<<<<< HEAD\nours2\n||||||| base\nbase2\n=======\ntheirs2\ntheirs2b\n>>>>>>> feature\nc\n",
            markers: [2, 4, 6, 8, 10, 12, 15]
        )
        let conflicts = file.conflicts
        try #require(conflicts.count == 2)
        #expect(file.segments.count == 5)
        #expect(file.strayMarkerLines.isEmpty)

        #expect(file.text(of: conflicts[0].ours) == ["ours1"])
        #expect(conflicts[0].ours.firstLine == 3)
        #expect(conflicts[0].base == nil)
        #expect(file.text(of: conflicts[0].theirs) == ["theirs1"])
        #expect(conflicts[0].theirs.firstLine == 5)

        #expect(file.text(of: conflicts[1].ours) == ["ours2"])
        #expect(file.text(of: try #require(conflicts[1].base)) == ["base2"])
        #expect(file.text(of: conflicts[1].theirs) == ["theirs2", "theirs2b"])
        #expect(conflicts[1].theirs.firstLine == 13)
        #expect(conflicts[1].theirs.count == 2)

        guard case .lines(let first) = file.segments[0], case .lines(let between) = file.segments[2], case .lines(let last) = file.segments[4] else {
            Issue.record("Expected lines between the conflicts")
            return
        }
        #expect(file.text(of: first) == ["a"])
        #expect(file.text(of: between) == ["b"])
        #expect(between.firstLine == 7)
        #expect(file.text(of: last) == ["c"])
        #expect(last.firstLine == 16)
    }

    @Test("keeps one conflict's side, the rest of the file as it was")
    func keepsEachConflictsSide() {
        let file = text(
            "a\n<<<<<<< HEAD\nours1\n=======\ntheirs1\n>>>>>>> feature\nb\n<<<<<<< HEAD\nours2\n=======\ntheirs2\n>>>>>>> feature\nc\n",
            markers: [2, 4, 6, 8, 10, 12]
        )
        #expect(file.resolving(0, with: .theirs).map { String(decoding: $0, as: UTF8.self) }
            == "a\ntheirs1\nb\n<<<<<<< HEAD\nours2\n=======\ntheirs2\n>>>>>>> feature\nc\n")
        #expect(file.resolving(1, with: .ours).map { String(decoding: $0, as: UTF8.self) }
            == "a\n<<<<<<< HEAD\nours1\n=======\ntheirs1\n>>>>>>> feature\nb\nours2\nc\n")
        #expect(file.resolving(2, with: .ours) == nil)
    }

    /// A file, its markers' lines, the side kept of its first conflict, and
    /// the file after.
    struct Resolution: Sendable {
        let contents: String
        let markers: [Int]
        let side: ManualConflictResolution
        let expected: String
    }

    @Test("keeps the file's bytes around the side kept", arguments: [
        NamedCase("CRLF line endings", Resolution(
            contents: "x\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> b\r\ny\r\n",
            markers: [2, 4, 6], side: .theirs, expected: "x\r\ntheirs\r\ny\r\n"
        )),
        NamedCase("no newline after the last line", Resolution(
            contents: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\ntail",
            markers: [1, 3, 5], side: .ours, expected: "ours\ntail"
        )),
        NamedCase("the closing marker ends the file without a newline", Resolution(
            contents: "head\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b",
            markers: [2, 4, 6], side: .ours, expected: "head\nours"
        )),
        NamedCase("the closing marker ends a CRLF file without a line ending", Resolution(
            contents: "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> b",
            markers: [1, 3, 5], side: .theirs, expected: "theirs"
        )),
        NamedCase("an empty side", Resolution(
            contents: "a\n<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> b\nz\n",
            markers: [2, 3, 5], side: .ours, expected: "a\nz\n"
        )),
        NamedCase("the common ancestor's lines left out", Resolution(
            contents: "<<<<<<< HEAD\nours\n||||||| base\nbase\n=======\ntheirs\n>>>>>>> b\n",
            markers: [1, 3, 5, 7], side: .theirs, expected: "theirs\n"
        )),
        NamedCase("longer markers, a seven-character one on our side", Resolution(
            contents: "<<<<<<<<<< HEAD\nours\n=======\n==========\ntheirs\n>>>>>>>>>> b\n",
            markers: [1, 4, 6], side: .ours, expected: "ours\n=======\n"
        )),
        NamedCase("a marker-like line git reported on their side", Resolution(
            contents: "<<<<<<< HEAD\nours\n=======\n=======\ntheirs\n>>>>>>> b\n",
            markers: [1, 3, 4, 6], side: .theirs, expected: "=======\ntheirs\n"
        )),
    ])
    func resolution(_ resolution: NamedCase<Resolution>) throws {
        let value = resolution.value
        let file = text(value.contents, markers: value.markers)
        try #require(file.conflicts.count == 1)
        let resolved = try #require(file.resolving(0, with: value.side))
        #expect(resolved == Data(value.expected.utf8))
    }

    @Test("CRLF lines' text leaves out the carriage return")
    func crlfText() throws {
        let file = text("<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> b\r\n", markers: [1, 3, 5])
        let conflict = try #require(file.conflicts.first)
        #expect(file.text(of: conflict.ours) == ["ours"])
        #expect(file.text(of: conflict.theirs) == ["theirs"])
    }

    /// A file with markers that make no whole conflict, and the stray ones.
    struct Stray: Sendable {
        let contents: String
        let markers: [Int]
        let conflicts: Int
        let stray: Set<Int>
    }

    @Test("markers that make no whole conflict stay with the lines around them", arguments: [
        NamedCase("never closed", Stray(contents: "<<<<<<< HEAD\nours\n=======\ntheirs\n", markers: [1, 3], conflicts: 0, stray: [1, 3])),
        NamedCase("closed before the separator", Stray(contents: "<<<<<<< HEAD\nours\n>>>>>>> b\n", markers: [1, 3], conflicts: 0, stray: [1, 3])),
        NamedCase("a separator outside a conflict", Stray(contents: "a\n=======\nb\n", markers: [2], conflicts: 0, stray: [2])),
        NamedCase("opened again", Stray(
            contents: "<<<<<<< a\nx\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\n",
            markers: [1, 3, 5, 7],
            conflicts: 1,
            stray: [1]
        )),
    ])
    func stray(_ stray: NamedCase<Stray>) {
        let file = text(stray.value.contents, markers: stray.value.markers)
        #expect(file.conflicts.count == stray.value.conflicts)
        #expect(file.strayMarkerLines == stray.value.stray)
        // Every line is in a segment, once.
        let lineCount = file.segments.reduce(0) { count, segment in
            switch segment {
            case .lines(let lines):
                count + lines.count
            case .conflict(let conflict):
                count + conflict.ours.count + (conflict.base?.count ?? 0) + conflict.theirs.count + (conflict.base == nil ? 3 : 4)
            }
        }
        #expect(lineCount == stray.value.contents.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
    }

    // MARK: The markers git reports

    @Test("git reports a merge's markers in one file, and the file divides at them")
    func reportedMarkers() async throws {
        let repository = try await setupConflictedRepo()
        #expect(try await getConflictMarkerLines(repository, path: "foo") == [1, 3, 5])
        let file = try #require(try await getConflictedFileText(repository, path: "foo"))
        let conflict = try #require(file.conflicts.first)
        #expect(file.conflicts.count == 1)
        #expect(file.text(of: conflict.ours) == ["b2"])
        #expect(file.text(of: conflict.theirs) == ["b1"])
    }

    @Test("git reports markers of the size the conflict-marker-size attribute sets")
    func markerSize() async throws {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "1\n2\n3\n")]))
        _ = try await Dugite.exec(["branch", "other"], repository.path)
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "1\ntwo\n3\n")]))
        try await switchTo(repository, "other")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a.txt", contents: "1\ndeux\n3\n")]))
        let attributes = POSIXPath.join(repository.path, ".git", "info", "attributes")
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(attributes), withIntermediateDirectories: true)
        try Data("a.txt conflict-marker-size=10\n".utf8).write(to: URL(filePath: attributes))
        _ = try await Dugite.exec(["merge", "master"], repository.path)

        let contents = try String(contentsOfFile: POSIXPath.join(repository.path, "a.txt"), encoding: .utf8)
        #expect(contents.hasPrefix("1\n<<<<<<<<<< HEAD\n"))
        #expect(try await getConflictMarkerLines(repository, path: "a.txt") == [2, 4, 6])
        let file = try #require(try await getConflictedFileText(repository, path: "a.txt"))
        let conflict = try #require(file.conflicts.first)
        #expect(file.text(of: conflict.ours) == ["deux"])
        #expect(file.text(of: conflict.theirs) == ["two"])
    }
}

// Ported from desktop/app/test/unit/status-parser-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

private func parse(_ input: String) throws -> [StatusItem] {
    try parsePorcelainStatus(Data(input.utf8))
}

/// Every parsed item in these inputs is an entry.
private func parseEntries(_ input: String) throws -> [StatusEntry] {
    let items = try parse(input)
    let entries = items.compactMap(\.entry)
    #expect(entries.count == items.count)
    return entries
}

@Suite("parsePorcelainStatus")
struct StatusParserTests {
    @Test("parses a standard status")
    func parsesStandardStatus() throws {
        let entries = try parseEntries(
            [
                "1 .D N... 100644 100644 000000 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 deleted",
                "1 .M N... 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
                "? untracked",
            ].joined(separator: "\0") + "\0"
        )

        #expect(entries.count == 3)

        var i = 0
        #expect(entries[i].statusCode == ".D")
        #expect(entries[i].path == "deleted")
        i += 1

        #expect(entries[i].statusCode == ".M")
        #expect(entries[i].path == "modified")
        i += 1

        #expect(entries[i].statusCode == "??")
        #expect(entries[i].path == "untracked")
    }

    @Test("parses renames")
    func parsesRenames() throws {
        let entries = try parseEntries(
            [
                "2 R. N... 100644 100644 100644 2de0487c2d3e977f5f560b746833f9d7f9a054fd 2de0487c2d3e977f5f560b746833f9d7f9a054fd R100 new\0old",
                "2 RM N... 100644 100644 100644 a3cba7afce66ef37a228e094273c27141db21f36 a3cba7afce66ef37a228e094273c27141db21f36 R100 to\0from",
            ].joined(separator: "\0") + "\0"
        )

        #expect(entries.count == 2)

        var i = 0

        #expect(entries[i].statusCode == "R.")
        #expect(entries[i].path == "new")
        #expect(entries[i].oldPath == "old")
        i += 1

        #expect(entries[i].statusCode == "RM")
        #expect(entries[i].path == "to")
        #expect(entries[i].oldPath == "from")
    }

    @Test("ignores ignored files")
    func ignoresIgnoredFiles() throws {
        // We don't run status with --ignored so this shouldn't be a problem
        // but we test it all the same

        let entries = try parse(["! foo"].joined(separator: "\0") + "\0")

        #expect(entries.count == 0)
    }

    @Test("parses status headers")
    func parsesStatusHeaders() throws {
        // We don't run status with --ignored so this shouldn't be a problem
        // but we test it all the same

        let items = try parse(
            [
                "# branch.oid 2de0487c2d3e977f5f560b746833f9d7f9a054fd",
                "# branch.head master",
                "# branch.upstream origin/master",
                "# branch.ab +1 -0",
            ].joined(separator: "\0") + "\0"
        )
        let entries = items.compactMap(\.header)

        #expect(entries.count == 4)
        #expect(items.count == 4)

        var i = 0

        #expect(entries[i].value == "branch.oid 2de0487c2d3e977f5f560b746833f9d7f9a054fd")
        i += 1
        #expect(entries[i].value == "branch.head master")
        i += 1
        #expect(entries[i].value == "branch.upstream origin/master")
        i += 1
        #expect(entries[i].value == "branch.ab +1 -0")
    }

    @Test("parses a path which includes a newline")
    func parsesPathWithNewline() throws {
        let x = """
            1 D. N... 100644 000000 000000 dc9fb24e86f7445720b39dcb39a7fc0e410d9583 0000000000000000000000000000000000000000 ProjectSID/Images.xcassets/iPhone 67/Status Center/Report X68 Y461
                  /.DS_Store
            """
        let entries = try parseEntries(x)

        #expect(entries.count == 1)

        let expectedPath = """
            ProjectSID/Images.xcassets/iPhone 67/Status Center/Report X68 Y461
                  /.DS_Store
            """

        #expect(entries[0].path == expectedPath)
        #expect(entries[0].statusCode == "D.")
    }

    @Test("parses a typechange")
    func parsesTypechange() throws {
        let x =
            "1 .T N... 120000 120000 100755 6165716e8b408ad09b51d1a37aa1ef50e7f84376 6165716e8b408ad09b51d1a37aa1ef50e7f84376 pdf_linux-x64/lib/libQt5Core.so.5"
        let entries = try parseEntries(x)

        #expect(entries.count == 1)

        #expect(entries[0].path == "pdf_linux-x64/lib/libQt5Core.so.5")
        #expect(entries[0].statusCode == ".T")
    }

    @Test("parses submodule changes")
    func parsesSubmoduleChanges() throws {
        let x =
            "1 .M SCMU 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 submodule/submodule"
        let entries = try parseEntries(x)
        #expect(entries.count == 1)
        #expect(entries[0].path == "submodule/submodule")
        #expect(entries[0].submoduleStatusCode == "SCMU")
    }

    // The byte parser must accept and reject exactly what the JavaScript
    // regular expressions do.

    @Test("parses unmerged entries, copies, and rename scores")
    func parsesUnmergedAndCopies() throws {
        let entries = try parseEntries(
            [
                "u UU N... 100644 100644 100644 100644 257cc5642cb1a054f08cc83f2d943e56fd3ebe99 5716ca5987cbf97d6bb54920bea6adde242d87e6 76018072e09c5d31c8c6e3113b8aa0fe625195ca both modified",
                "2 C. N... 100644 100644 100644 2de0487c2d3e977f5f560b746833f9d7f9a054fd 2de0487c2d3e977f5f560b746833f9d7f9a054fd C75 copy\0original",
                "? dir/untracked file",
            ].joined(separator: "\0") + "\0"
        )

        #expect(entries == [
            StatusEntry(path: "both modified", statusCode: "UU", submoduleStatusCode: "N..."),
            StatusEntry(path: "copy", statusCode: "C.", submoduleStatusCode: "N...", oldPath: "original", renameOrCopyScore: 75),
            StatusEntry(path: "dir/untracked file", statusCode: "??", submoduleStatusCode: "????"),
        ])
    }

    @Test("rejects malformed entries", arguments: [
        // Uppercase object IDs.
        "1 .M N... 100644 100644 100644 E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
        // A status code outside the allowed characters.
        "1 .Z N... 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
        // A bad submodule code.
        "1 .M SXMU 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
        // Two spaces between fields.
        "1 .M N...  100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
        // Unicode digits are not `\d` in JavaScript.
        "1 .M N... 1006\u{0664}4 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 modified",
        // No path separator.
        "1 .M N... 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        // An unmerged entry with a status code outside [DAU].
        "u UM N... 100644 100644 100644 100644 257cc5642cb1a054f08cc83f2d943e56fd3ebe99 5716ca5987cbf97d6bb54920bea6adde242d87e6 76018072e09c5d31c8c6e3113b8aa0fe625195ca file",
        // A rename without its score.
        "2 R. N... 100644 100644 100644 2de0487c2d3e977f5f560b746833f9d7f9a054fd 2de0487c2d3e977f5f560b746833f9d7f9a054fd new\0old",
        // A rename without its old path.
        "2 R. N... 100644 100644 100644 2de0487c2d3e977f5f560b746833f9d7f9a054fd 2de0487c2d3e977f5f560b746833f9d7f9a054fd R100 new",
        "2 R. N... 100644 100644 100644 2de0487c2d3e977f5f560b746833f9d7f9a054fd 2de0487c2d3e977f5f560b746833f9d7f9a054fd R100 new\0",
    ])
    func rejectsMalformedEntries(_ input: String) {
        #expect(throws: GitLibError.self) {
            _ = try parse(input)
        }
    }

    @Test("accepts an empty path and decodes invalid UTF-8 as desktop does")
    func emptyPathAndInvalidUTF8() throws {
        var bytes = Data("1 .M N... 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 ".utf8)
        bytes.append(0)
        bytes.append(contentsOf: Data("? caf".utf8) + [0xC3, 0x0A, 0xE9])
        bytes.append(0)

        let entries = try parsePorcelainStatus(bytes).compactMap(\.entry)
        #expect(entries.map(\.path) == ["", "caf\u{FFFD}\n\u{FFFD}"])
    }

    // A regression bound, not a benchmark: parsing 40 times the entries
    // takes about 40 times the work, and only something like quadratic
    // work could take 6 times that. Work is CPU time on this thread, the
    // least of a few runs, which other work on the machine doesn't add to.
    @Test("parses 20,000 entries in linear time")
    func manyEntriesBound() throws {
        let sha = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        func output(_ count: Int) -> Data {
            var output = "# branch.oid \(sha)\0# branch.head main\0"
            for index in 0..<count {
                output += "1 .M N... 100644 100644 100644 \(sha) \(sha) dir/file-\(index).txt\0"
                output += "? untracked/file-\(index).txt\0"
            }
            return Data(output.utf8)
        }
        let large = output(10_000)
        let small = output(250)

        var count = 0
        let largeTime = try leastThreadCPUTime(runs: 3) {
            count = try parsePorcelainStatus(large).count
        }
        let smallTime = try leastThreadCPUTime(runs: 5) {
            _ = try parsePorcelainStatus(small)
        }

        #expect(count == 20_002)
        #expect(largeTime < smallTime * 40 * 6, "parsing 20,000 entries took \(largeTime), 500 entries \(smallTime)")
    }

    @Test("keeps branch headers and ignores fields that only look like them")
    func headerEdgeCases() throws {
        let items = try parse(["# ", "#", "# x", "#branch"].joined(separator: "\0"))
        #expect(items == [.header(StatusHeader(value: "x"))])
    }
}

@Suite("mapStatus (status codes)")
struct MapStatusCodeTests {
    @Test("maps the codes desktop lists, and falls back to modified")
    func mapsCodes() {
        #expect(mapStatus("??", "????", nil) == .untracked(UntrackedEntry()))
        #expect(mapStatus("AD", "N...", nil) == .ordinary(OrdinaryEntry(type: .added, index: .added, workingTree: .deleted)))
        #expect(mapStatus("RM", "N...", 90) == .renamed(RenamedOrCopiedEntry(index: .renamed, workingTree: .modified, renameOrCopyScore: 90)))
        #expect(mapStatus("C.", "N...", 80) == .copied(RenamedOrCopiedEntry(index: .copied, workingTree: .unchanged)))
        #expect(mapStatus("UD", "N...", nil) == .conflicted(UnmergedEntry(action: .deletedByThem)))
        #expect(mapStatus("MM", "N...", nil) == .ordinary(OrdinaryEntry(type: .modified)))
        #expect(mapStatus(".T", "N...", nil) == .ordinary(OrdinaryEntry(type: .modified)))
    }

    @Test("maps submodule status codes")
    func mapsSubmoduleCodes() {
        let submodule = mapStatus(".M", "SC.U", nil).submoduleStatus
        #expect(submodule == SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: true))
        #expect(mapStatus(".M", "N...", nil).submoduleStatus == nil)
        // Past the end, a code counts as unchanged (JavaScript's undefined).
        #expect(mapStatus(".M", "S", nil).submoduleStatus == SubmoduleStatus(commitChanged: false, modifiedChanges: false, untrackedChanges: false))
    }
}

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The printenvz script.
@Suite("printenvz")
struct PrintenvzTests {
    @Test("writes an executable script that prints the environment between markers")
    func writesScript() async throws {
        let directory = try createTempDirectory()
        let path = try getPrintenvzPath(in: directory)

        #expect(path == POSIXPath.join(directory, "espalier-printenvz"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(attributes[.posixPermissions] as? Int == 0o700)

        let stdout = try await runProcess(path, environment: [
            "FOO": "bar baz",
            "EMPTY": "",
            "MULTILINE": "line1\nline2",
            "EQUALS": "a=b",
        ])
        let output = String(decoding: stdout, as: UTF8.self)

        #expect(output.hasPrefix("--printenvz--begin\n"))
        #expect(output.hasSuffix("\0\n--printenvz--end\n"))
        let env = try parsePrintenvzOutput(output)
        #expect(env["FOO"] == "bar baz")
        #expect(env["EMPTY"] == "")
        #expect(env["MULTILINE"] == "line1\nline2")
        #expect(env["EQUALS"] == "a=b")
    }

    @Test("re-creates the script when it is missing")
    func recreatesMissingScript() throws {
        let directory = try createTempDirectory()
        let path = try getPrintenvzPath(in: directory)
        try FileManager.default.removeItem(atPath: path)

        #expect(try getPrintenvzPath(in: directory) == path)
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("replaces a script that was changed, made non-executable, or linked")
    func replacesChangedScript() throws {
        let directory = try createTempDirectory()
        let path = try getPrintenvzPath(in: directory)
        let original = try Data(contentsOf: URL(filePath: path))

        try Data("#!/bin/sh\necho changed\n".utf8).write(to: URL(filePath: path))
        #expect(try getPrintenvzPath(in: directory) == path)
        #expect(try Data(contentsOf: URL(filePath: path)) == original)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        #expect(try getPrintenvzPath(in: directory) == path)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o700)

        // A symbolic link to a copy of the script is replaced by the script.
        let elsewhere = POSIXPath.join(try createTempDirectory(), "copy")
        try FileManager.default.copyItem(atPath: path, toPath: elsewhere)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: elsewhere)
        #expect(try getPrintenvzPath(in: directory) == path)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test("throws when the script can't be written")
    func throwsWhenUnwritable() throws {
        let missing = POSIXPath.join(try createTempDirectory(), "missing")
        #expect(throws: (any Error).self) {
            try getPrintenvzPath(in: missing)
        }
    }
}

/// Parsing printenvz's output from a login shell.
@Suite("parsePrintenvzOutput")
struct ParsePrintenvzOutputTests {
    @Test("parses the entries between the markers", arguments: [
        NamedCase("parses the entries between the markers", (
            output: "--printenvz--begin\nPATH=/usr/bin:/bin\0HOME=/Users/joe\0\n--printenvz--end\n",
            expected: ["PATH": "/usr/bin:/bin", "HOME": "/Users/joe"]
        )),
        NamedCase("accepts CRLF line endings around the markers", (
            output: "noise\r\n--printenvz--begin\r\nA=1\0B=2\0\r\n--printenvz--end\r\n",
            expected: ["A": "1", "B": "2"]
        )),
        NamedCase("keeps equals signs, newlines, and empty values", (
            output: "--printenvz--begin\nA=b=c\0B=\0C==\0ML=line1\nline2\0\n--printenvz--end\n",
            expected: ["A": "b=c", "B": "", "C": "=", "ML": "line1\nline2"]
        )),
        NamedCase("lets a later duplicate win", (
            output: "--printenvz--begin\nA=1\0A=2\0\n--printenvz--end\n",
            expected: ["A": "2"]
        )),
    ])
    func parsesEntries(_ testCase: NamedCase<(output: String, expected: [String: String])>) throws {
        #expect(try parsePrintenvzOutput(testCase.value.output) == testCase.value.expected)
    }

    @Test("ignores output from shell startup files before the begin marker")
    func ignoresOutputBeforeBeginMarker() throws {
        #expect(try parsePrintenvzOutput(
            "Last login: today\nmotd=hello\0\n--printenvz--begin?\n--printenvz--begin\nA=1\0\n--printenvz--end\n"
        ) == ["A": "1"])
        #expect(try parsePrintenvzOutput(
            "welcome\n--printenvz--end\n--printenvz--begin\nA=1\0\n--printenvz--end\n"
        ) == ["A": "1"])
    }

    @Test("uses the last end marker")
    func usesLastEndMarker() throws {
        // A value that contains the end marker.
        #expect(try parsePrintenvzOutput(
            "--printenvz--begin\nX=a\n--printenvz--end\nb\0Y=2\0\n--printenvz--end\n"
        ) == ["X": "a\n--printenvz--end\nb", "Y": "2"])
        // Output after the end marker, as from a logout script.
        #expect(try parsePrintenvzOutput(
            "--printenvz--begin\nA=1\0\n--printenvz--end\nbye\n"
        ) == ["A": "1"])
        // Matches don't overlap, so the second marker, which would need the
        // first one's newline, isn't one.
        #expect(try parsePrintenvzOutput(
            "--printenvz--begin\nA=1\0\n--printenvz--end\n--printenvz--end\n"
        ) == ["A": "1"])
    }

    @Test("parses an empty environment")
    func parsesEmptyEnvironment() throws {
        #expect(try parsePrintenvzOutput("--printenvz--begin\n\n--printenvz--end\n") == [:])
        // An end marker only before the begin marker: JavaScript's substring
        // swaps the bounds, leaving no entries.
        #expect(try parsePrintenvzOutput("\n--printenvz--end\nxx--printenvz--begin\nA=1\0") == [:])
    }

    @Test("throws when a marker is missing")
    func throwsWithoutMarkers() {
        #expect(throws: ShellEnvError.missingStartMarker) {
            try parsePrintenvzOutput("A=1\0\n--printenvz--end\n")
        }
        #expect(throws: ShellEnvError.missingEndMarker) {
            try parsePrintenvzOutput("--printenvz--begin\nA=1\0")
        }
        #expect(ShellEnvError.missingStartMarker.description == "could not find start marker in shell output")
        #expect(ShellEnvError.missingEndMarker.description == "could not find end marker in shell output")
    }

    @Test("matches Unicode scalars like desktop's regexes")
    func matchesUnicodeScalars() throws {
        // Entries without "=" run into the next key.
        #expect(try parsePrintenvzOutput(
            "--printenvz--begin\n=lead\0NOEQ\0B=2\0\n--printenvz--end\n"
        ) == ["lead\0NOEQ\0B": "2"])
        // A combining mark after "=" forms one grapheme cluster with it.
        #expect(try parsePrintenvzOutput(
            "--printenvz--begin\nE=\u{301}z\0F=e\u{301}\0\n--printenvz--end\n"
        ) == ["E": "\u{301}z", "F": "e\u{301}"])
    }
}

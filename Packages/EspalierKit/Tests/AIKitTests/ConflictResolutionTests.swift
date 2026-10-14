// Ported from desktop/app/test/unit/copilot-conflict-resolution-test.ts

@testable import AIKit
import Foundation
import Testing
import TestSupport

// MARK: Helpers

/// `JSON.stringify(value)`.
private func stringify(_ value: JSONValue) -> String {
    String(decoding: value.serialized(), as: UTF8.self)
}

/// A resolution entry in the per-hunk format the parser expects.
private func makeResolution(_ path: String, _ resolvedContent: [String], _ reasoning: String) -> JSONValue {
    [
        "path": .string(path),
        "hunks": .array(resolvedContent.map { ["resolvedContent": .string($0)] }),
        "reasoning": .string(reasoning),
    ]
}

private func makeResolution(_ path: String, _ resolvedContent: String, _ reasoning: String) -> JSONValue {
    makeResolution(path, [resolvedContent], reasoning)
}

private func payload(_ resolutions: [JSONValue], extra: [String: JSONValue] = [:]) -> String {
    var object: JSONObject = ["resolutions": .array(resolutions)]
    for (key, value) in extra {
        object[key] = value
    }
    return stringify(.object(object))
}

private func makeFile(
    _ path: String,
    _ oursContent: String,
    _ theirsContent: String,
    baseContent: String? = nil,
    contextBefore: String = "",
    contextAfter: String = ""
) -> FileConflictContext {
    FileConflictContext(
        path: path,
        hunks: [
            ConflictHunk(
                oursContent: oursContent,
                theirsContent: theirsContent,
                baseContent: baseContent,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            ),
        ]
    )
}

private func paths(_ chunks: [[FileConflictContext]]) -> [[String]] {
    chunks.map { $0.map(\.path) }
}

private func expectValidationError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    #expect(throws: AIValidationError.self, sourceLocation: sourceLocation) {
        try body()
    }
}

/// The paths of the resolutions in `json` that the parser set aside as
/// invalid, checking that it found no valid ones.
private func invalidPaths(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
    let result = try parseAIConflictResolution(json)
    #expect(result.resolutions.isEmpty, sourceLocation: sourceLocation)
    return result.invalidResolutions.map(\.path)
}

// MARK: parseAIConflictResolution

@Suite("parseCopilotConflictResolution")
struct ParseConflictResolutionTests {
    @Test("parses a valid JSON response")
    func parsesValid() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("src/index.ts", "content", "combined both")]))
        #expect(result.resolutions.count == 1)
        #expect(result.resolutions[0].path == "src/index.ts")
        #expect(result.resolutions[0].hunks[0].resolvedContent == "content")
        #expect(result.resolutions[0].reasoning == "combined both")
    }

    @Test("unwraps ``` code blocks without json tag")
    func unwrapsPlainFence() throws {
        let wrapped = "```\n" + payload([makeResolution("a.ts", "x", "r")]) + "\n```"
        #expect(try parseAIConflictResolution(wrapped).resolutions[0].path == "a.ts")
    }

    @Test("throws on invalid JSON")
    func invalidJSON() {
        expectValidationError { _ = try parseAIConflictResolution("not json") }
    }

    @Test("throws on non-object payload")
    func nonObject() {
        expectValidationError { _ = try parseAIConflictResolution(#""string""#) }
    }

    @Test("throws on missing resolutions array")
    func missingResolutions() {
        expectValidationError { _ = try parseAIConflictResolution(#"{"foo":"bar"}"#) }
    }

    @Test("throws on empty resolutions array")
    func emptyResolutions() {
        expectValidationError {
            _ = try parseAIConflictResolution(#"{"resolutions":[]}"#)
        }
    }

    @Test("leaves out a resolution without a path, which no file can claim")
    func missingPath() throws {
        for entry: JSONValue in [
            ["hunks": [["resolvedContent": "c"]], "reasoning": "r"],
            ["path": "  ", "hunks": [["resolvedContent": "c"]], "reasoning": "r"],
            "a.ts",
        ] {
            let result = try parseAIConflictResolution(payload([entry, makeResolution("b.ts", "c", "r")]))
            #expect(result.resolutions.map(\.path) == ["b.ts"])
            #expect(result.invalidResolutions.isEmpty)
        }
    }

    @Test("sets aside, under its path, a text resolution without hunks, beside the valid ones")
    func missingHunks() throws {
        let result = try parseAIConflictResolution(
            payload([["path": "a.ts", "reasoning": "r"], ["path": "b.ts", "hunks": [], "reasoning": "r"], makeResolution("c.ts", "c", "r")])
        )
        #expect(result.resolutions.map(\.path) == ["c.ts"])
        #expect(result.invalidResolutions.map(\.path) == ["a.ts", "b.ts"])
    }

    @Test("accepts a missing, blank, or mistyped reasoning as none")
    func missingReasoning() throws {
        for reasoning: JSONValue? in [nil, "", "  ", 3] {
            var entry: JSONObject = ["path": "a.ts", "hunks": [["resolvedContent": "c"]]]
            entry["reasoning"] = reasoning
            let result = try parseAIConflictResolution(payload([.object(entry)]))
            #expect(result.resolutions.map(\.reasoning) == [reasoning?.stringValue ?? ""])
        }
    }

    @Test("allows empty resolvedContent in a hunk (intentional deletion)")
    func emptyResolvedContent() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("a.ts", "", "emptied")]))
        #expect(result.resolutions[0].hunks[0].resolvedContent == "")
    }

    @Test("handles resolvedContent containing triple backticks")
    func tripleBackticksInContent() throws {
        let json = payload([makeResolution("README.md", "# Hello\n```js\nconsole.log()\n```\n", "kept code block")])
        let result = try parseAIConflictResolution("```json\n" + json + "\n```")
        #expect(result.resolutions[0].path == "README.md")
        #expect(result.resolutions[0].hunks[0].resolvedContent.contains("```js"))
    }

    @Test("parses when LLM adds preamble/postamble around code block")
    func preambleAndPostamble() throws {
        let content = "Here is my answer:\n```json\n" + payload([makeResolution("a.ts", "fixed", "merged")])
            + "\n```\nHope this helps!"
        #expect(try parseAIConflictResolution(content).resolutions[0].path == "a.ts")
    }

    @Test("does not reject resolvedContent with only opening marker in a comment")
    func openingMarkerInComment() throws {
        let json = payload([makeResolution("a.ts", "// <<<<<<< this is just a comment\nreal code", "fine")])
        // Only rejected when both an opening marker and a separator are present.
        #expect(try parseAIConflictResolution(json).resolutions[0].path == "a.ts")
    }

    @Test("sets aside truncated conflict markers (opening + separator without closing)")
    func truncatedMarkers() throws {
        let json = payload([makeResolution("a.ts", "<<<<<<< HEAD\nours\n=======\ntheirs but truncated", "truncated")])
        #expect(try invalidPaths(json) == ["a.ts"])
    }

    @Test("parses JSON block followed by another code block")
    func followedByAnotherBlock() throws {
        let content = "```json\n" + payload([makeResolution("a.ts", "fixed", "merged")])
            + "\n```\n\nYou can verify with:\n```bash\nnpm test\n```"
        #expect(try parseAIConflictResolution(content).resolutions[0].path == "a.ts")
    }

    @Test("keeps each path as the model wrote it, for matching to the files")
    func rawPaths() throws {
        let result = try parseAIConflictResolution(payload([makeResolution(" ./src\\lib//file.ts ", "content", "reason")]))
        #expect(result.resolutions[0].path == " ./src\\lib//file.ts ")
    }

    @Test("returns null summary when missing, mistyped, or blank")
    func nullSummary() throws {
        let base = [makeResolution("a.ts", "c", "r")]
        for summary: JSONValue? in [nil, .number(42), .string("   ")] {
            let json = payload(base, extra: summary.map { ["summary": $0] } ?? [:])
            #expect(try parseAIConflictResolution(json).summary == nil)
        }
    }

    @Test("preserves a non-empty summary string")
    func preservesSummary() throws {
        let summary = "## What changed\nA.\n\n## Resolution decision\nB."
        let json = payload([makeResolution("a.ts", "c", "r")], extra: ["summary": .string(summary)])
        #expect(try parseAIConflictResolution(json).summary == summary)
    }

    @Test("parses valid references and strips a leading # from PR ids")
    func parsesReferences() throws {
        let json = payload(
            [makeResolution("a.ts", "c", "r")],
            extra: [
                "references": [
                    ["type": "pullRequest", "id": "#42"],
                    ["type": "commit", "id": "abc1234"],
                ],
            ]
        )
        #expect(
            try parseAIConflictResolution(json).references == [
                AIConflictReference(type: .pullRequest, id: "42"),
                AIConflictReference(type: .commit, id: "abc1234"),
            ]
        )
    }

    @Test("returns empty references when missing and drops invalid entries")
    func dropsInvalidReferences() throws {
        let missing = payload([makeResolution("a.ts", "c", "r")])
        #expect(try parseAIConflictResolution(missing).references == [])

        let json = payload(
            [makeResolution("a.ts", "c", "r")],
            extra: [
                "references": [
                    ["type": "wrong", "id": "1"],
                    ["type": "pullRequest", "id": "abc"],
                    ["type": "commit", "id": "xyz"],
                    ["type": "commit", "id": "cafe1234"],
                    "string",
                    nil,
                ],
            ]
        )
        #expect(try parseAIConflictResolution(json).references == [AIConflictReference(type: .commit, id: "cafe1234")])
    }

    // -- Delete-vs-modify conflict action tests --

    @Test("parses a delete-vs-modify resolution with action \"keep\"")
    func actionKeep() throws {
        let json = payload([["path": "deleted.ts", "hunks": [], "reasoning": "File has useful changes", "action": "keep"]])
        let result = try parseAIConflictResolution(json)
        #expect(result.resolutions.count == 1)
        #expect(result.resolutions[0].path == "deleted.ts")
        #expect(result.resolutions[0].action == .keep)
        #expect(result.resolutions[0].hunks.isEmpty)
        #expect(result.resolutions[0].reasoning == "File has useful changes")
    }

    @Test("handles mixed text and delete-vs-modify resolutions")
    func mixedActions() throws {
        let json = payload([
            makeResolution("text.ts", "resolved content", "merged both sides"),
            ["path": "deleted.ts", "hunks": [], "reasoning": "keep it", "action": "keep"],
        ])
        let result = try parseAIConflictResolution(json)
        #expect(result.resolutions.count == 2)
        #expect(result.resolutions[0].action == nil)
        #expect(result.resolutions[0].hunks.count == 1)
        #expect(result.resolutions[1].action == .keep)
        #expect(result.resolutions[1].hunks.isEmpty)
    }

    @Test("ignores unknown action values and treats as regular resolution")
    func unknownAction() throws {
        let json = payload([["path": "a.ts", "hunks": [["resolvedContent": "x"]], "reasoning": "reason", "action": "unknown"]])
        let result = try parseAIConflictResolution(json)
        #expect(result.resolutions[0].action == nil)
        #expect(result.resolutions[0].hunks.count == 1)
    }

    @Test("accepts a delete-vs-modify resolution with an empty reasoning or no hunks")
    func actionWithoutReasoningOrHunks() throws {
        let json = payload([
            ["path": "a.ts", "hunks": [], "reasoning": "", "action": "keep"],
            ["path": "b.ts", "reasoning": "Gone upstream.", "action": "delete"],
        ])
        let result = try parseAIConflictResolution(json)
        #expect(result.resolutions == [
            RawFileResolution(path: "a.ts", hunks: [], reasoning: "", action: .keep),
            RawFileResolution(path: "b.ts", hunks: [], reasoning: "Gone upstream.", action: .delete),
        ])
        #expect(result.invalidResolutions.isEmpty)
    }

    @Test("finds conflict markers after any JavaScript line terminator")
    func markersAfterLineTerminators() throws {
        for content in [
            "x\r<<<<<<< a\r=======\r>>>>>>> b", "<<<<<<<\n=======", "x\u{2028}<<<<<<< a\u{2029}=======",
        ] {
            #expect(try invalidPaths(payload([makeResolution("a.ts", content, "r")])) == ["a.ts"], "\(content.debugDescription)")
        }
        for content in ["<<<<<<<x\n=======", " <<<<<<< a\n=======", "<<<<<<< a\n========", "<<<<<<< a\n=======x"] {
            let result = try parseAIConflictResolution(payload([makeResolution("a.ts", content, "r")]))
            #expect(result.invalidResolutions.isEmpty, "\(content.debugDescription)")
        }
    }
}

// MARK: reassembleResolvedFile

@Suite("reassembleResolvedFile")
struct ReassembleResolvedFileTests {
    @Test("replaces a single conflict in the middle of a file")
    func single() {
        let raw = ["line 1", "line 2", "<<<<<<< HEAD", "our change", "=======", "their change", ">>>>>>> feature", "line 3", "line 4"]
            .joined(separator: "\n")
        #expect(
            reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "merged change")])
                == ["line 1", "line 2", "merged change", "line 3", "line 4"].joined(separator: "\n")
        )
    }

    @Test("replaces multiple conflicts in order")
    func multiple() {
        let raw = [
            "header", "<<<<<<< HEAD", "our-1", "=======", "their-1", ">>>>>>> feature", "middle",
            "<<<<<<< HEAD", "our-2", "=======", "their-2", ">>>>>>> feature", "footer",
        ].joined(separator: "\n")
        #expect(
            reassembleResolvedFile(
                raw,
                [HunkResolution(resolvedContent: "resolved-1"), HunkResolution(resolvedContent: "resolved-2")]
            ) == ["header", "resolved-1", "middle", "resolved-2", "footer"].joined(separator: "\n")
        )
    }

    @Test("handles diff3 (three-way) markers")
    func diff3() {
        let raw = ["before", "<<<<<<< HEAD", "ours", "||||||| base", "original", "=======", "theirs", ">>>>>>> feature", "after"]
            .joined(separator: "\n")
        #expect(
            reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "merged")])
                == ["before", "merged", "after"].joined(separator: "\n")
        )
    }

    @Test("handles empty resolved content (intentional deletion)")
    func emptyResolution() {
        let raw = ["keep this", "<<<<<<< HEAD", "delete me", "=======", "also delete", ">>>>>>> feature", "keep this too"]
            .joined(separator: "\n")
        #expect(
            reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "")])
                == ["keep this", "keep this too"].joined(separator: "\n")
        )
    }

    @Test("handles multi-line resolved content")
    func multiLine() {
        let raw = ["start", "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> feature", "end"].joined(separator: "\n")
        #expect(
            reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "line1\nline2\nline3")])
                == ["start", "line1", "line2", "line3", "end"].joined(separator: "\n")
        )
    }

    @Test("preserves CRLF line endings")
    func crlf() {
        let raw = ["line 1", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "line 2"].joined(separator: "\r\n")
        #expect(
            reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "merged")])
                == ["line 1", "merged", "line 2"].joined(separator: "\r\n")
        )
    }

    @Test("keeps each line's own ending; spliced lines take the ending of the line before their block, a resolution's final one ending its last line", arguments: [
        NamedCase(
            "an LF file with CRLF lines elsewhere keeps both",
            (raw: "a\r\nb\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nc\r\nd\n", resolutions: ["x\ny"], expected: "a\r\nb\nx\ny\nc\r\nd\n")
        ),
        NamedCase(
            "a CRLF region of an LF file splices CRLF lines",
            (
                raw: "a\nb\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nc\n",
                resolutions: ["x\ny"],
                expected: "a\nb\r\nx\r\ny\r\nc\n"
            )
        ),
        NamedCase(
            "two blocks in regions with different endings",
            (
                raw: "a\n<<<<<<< HEAD\no\n=======\nt\n>>>>>>> f\nb\r\n<<<<<<< HEAD\r\no\r\n=======\r\nt\r\n>>>>>>> f\r\nc",
                resolutions: ["x", "y"],
                expected: "a\nx\nb\r\ny\r\nc"
            )
        ),
        NamedCase(
            "an all-CRLF file with a final newline",
            (
                raw: "a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nb\r\n",
                resolutions: ["merged"],
                expected: "a\r\nmerged\r\nb\r\n"
            )
        ),
        NamedCase(
            "an all-CRLF file whose block ends it",
            (raw: "a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n", resolutions: ["x\ny"], expected: "a\r\nx\r\ny\r\n")
        ),
        NamedCase(
            "a block at the start of the file takes the opening marker's ending",
            (raw: "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nb\n", resolutions: ["x"], expected: "x\r\nb\n")
        ),
        NamedCase(
            "a file without a final newline keeps its last line as it was",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nb", resolutions: ["merged"], expected: "a\nmerged\nb")
        ),
        NamedCase(
            "a block that ends a file without a final newline leaves it without one",
            (raw: "a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature", resolutions: ["x\ny"], expected: "a\r\nx\r\ny")
        ),
        NamedCase(
            "deleting a block that ends a file leaves the line before it as it was",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature", resolutions: [""], expected: "a\n")
        ),
        NamedCase(
            "a resolution written with CRLF takes the file's ending",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nb\n", resolutions: ["x\r\ny"], expected: "a\nx\ny\nb\n")
        ),
        NamedCase(
            "a trailing LF in a resolution ends its last line",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nb\n", resolutions: ["x\ny\n"], expected: "a\nx\ny\nb\n")
        ),
        NamedCase(
            "a trailing CRLF in a resolution ends its last line",
            (
                raw: "a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nb\r\n",
                resolutions: ["x\r\n"],
                expected: "a\r\nx\r\nb\r\n"
            )
        ),
        NamedCase(
            "two trailing newlines in a resolution keep one blank line",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nb\n", resolutions: ["x\n\n"], expected: "a\nx\n\nb\n")
        ),
        NamedCase(
            "a resolution of only a line ending is an empty line",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nb\n", resolutions: ["\n"], expected: "a\n\nb\n")
        ),
        NamedCase(
            "a trailing newline in the last block of a file without a final newline leaves it without one",
            (raw: "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature", resolutions: ["x\n"], expected: "a\nx")
        ),
        NamedCase(
            "a lone CR is part of its line",
            (raw: "a\rb\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nc\r", resolutions: ["x"], expected: "a\rb\nx\nc\r")
        ),
    ])
    func lineEndings(_ testCase: NamedCase<(raw: String, resolutions: [String], expected: String)>) {
        let (raw, resolutions, expected) = testCase.value
        let resolved = reassembleResolvedFile(raw, resolutions.map(HunkResolution.init(resolvedContent:)))
        #expect(Array(resolved.utf8) == Array(expected.utf8))
    }

    @Test("preserves file with no conflicts unchanged")
    func noConflicts() {
        let raw = "line 1\nline 2\nline 3"
        #expect(reassembleResolvedFile(raw, []) == raw)
    }

    @Test("treats malformed markers (missing separator) as regular content")
    func missingSeparator() {
        let raw = ["line 1", "<<<<<<< HEAD", "some content", ">>>>>>> feature", "line 2"].joined(separator: "\n")
        // No ======= separator: not a valid conflict block, so it's copied through.
        #expect(reassembleResolvedFile(raw, []) == raw)
    }

    @Test("treats unclosed markers (missing >>>>>>>) as regular content")
    func missingClosing() {
        let raw = ["line 1", "<<<<<<< HEAD", "some content", "=======", "other content", "line 2"].joined(separator: "\n")
        // No >>>>>>> closing marker: not a valid conflict block, so it's copied through.
        #expect(reassembleResolvedFile(raw, []) == raw)
    }

    @Test("replaces exactly the blocks extractConflictHunks shows the model, even with malformed markers")
    func agreesWithExtraction() {
        let cases: [(lines: [String], ours: String, expected: [String])] = [
            // A block without a separator before a real one.
            (
                ["<<<<<<< stray", "x", ">>>>>>> stray", "<<<<<<< HEAD", "b", "=======", "c", ">>>>>>> branch", "end"],
                "x\n>>>>>>> stray\n<<<<<<< HEAD\nb",
                ["R", "end"]
            ),
            // A closing marker inside the ours section.
            (["start", "<<<<<<< HEAD", "a", ">>>>>>> x", "=======", "b", ">>>>>>> branch"], "a\n>>>>>>> x", ["start", "R"]),
            // A diff3 base without a separator before a real block.
            (
                ["<<<<<<< HEAD", "a", "||||||| base", "o", ">>>>>>> branch", "<<<<<<< HEAD", "c", "=======", "d", ">>>>>>> branch", "end"],
                "a",
                ["R", "end"]
            ),
        ]
        for (lines, ours, expected) in cases {
            let raw = lines.joined(separator: "\n")
            let hunks = extractConflictHunks(raw)
            #expect(hunks.map(\.oursContent) == [ours], "\(lines)")
            let resolved = reassembleResolvedFile(raw, [HunkResolution(resolvedContent: "R")])
            #expect(resolved == expected.joined(separator: "\n"), "\(lines)")
        }
    }
}

// MARK: checkResolutions

/// A parsed response with these resolutions.
private func response(_ resolutions: [RawFileResolution], invalid: [AIInvalidFileResolution] = []) -> AIConflictResolutionResponse {
    AIConflictResolutionResponse(resolutions: resolutions, invalidResolutions: invalid, summary: nil, references: [])
}

private func hunks(_ contents: String...) -> [HunkResolution] {
    contents.map(HunkResolution.init(resolvedContent:))
}

/// A text conflict with one hunk, and its file content.
private func conflicted(_ path: String) -> FileConflictContext {
    var file = makeFile(path, "ours", "theirs")
    file.rawContent = ["a", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "b"].joined(separator: "\n")
    return file
}

@Suite("checkResolutions")
struct CheckResolutionsTests {
    @Test("reassembles text resolutions and passes delete-vs-modify actions through, in the files' order")
    func mixed() {
        let checked = checkResolutions(
            response([
                RawFileResolution(path: "deleted.ts", hunks: [], reasoning: "keep file", action: .keep),
                RawFileResolution(path: "text.ts", hunks: hunks("merged"), reasoning: "combined both"),
            ]),
            [conflicted("text.ts"), FileConflictContext(path: "deleted.ts", hunks: [], deletedSide: .ours)]
        )
        #expect(
            checked.resolutions == [
                FileResolution(path: "text.ts", resolvedContent: "a\nmerged\nb", reasoning: "combined both"),
                FileResolution(path: "deleted.ts", resolvedContent: "", reasoning: "keep file", deleteConflictAction: .keep),
            ]
        )
        #expect(checked.unresolved.isEmpty)
    }

    @Test("fails only the files whose resolution is missing, doubled, invalid, or of the wrong shape")
    func failsFilesOnTheirOwn() {
        let files = ["ok.ts", "missing.ts", "twice.ts", "invalid.ts", "count.ts", "action.ts"].map(conflicted)
        let checked = checkResolutions(
            response(
                [
                    RawFileResolution(path: "ok.ts", hunks: hunks("merged"), reasoning: "r"),
                    RawFileResolution(path: "twice.ts", hunks: hunks("one"), reasoning: "r"),
                    RawFileResolution(path: "twice.ts", hunks: hunks("two"), reasoning: "r"),
                    RawFileResolution(path: "count.ts", hunks: hunks("x", "y"), reasoning: "r"),
                    RawFileResolution(path: "action.ts", hunks: [], reasoning: "r", action: .delete),
                    RawFileResolution(path: "unexpected.ts", hunks: hunks("x"), reasoning: "r"),
                ],
                invalid: [AIInvalidFileResolution(path: "invalid.ts", error: AIValidationError("No hunks"))]
            ),
            files
        )
        #expect(checked.resolutions.map(\.path) == ["ok.ts"])
        #expect(checked.unresolved.map(\.path) == ["missing.ts", "twice.ts", "invalid.ts", "count.ts", "action.ts"])
        #expect(checked.unresolved.allSatisfy { $0.stage == .validateResponse })
        #expect(checked.unresolved[2].error == AIValidationError("No hunks"))
    }

    @Test("accepts an action only for a delete-vs-modify conflict")
    func actionsOnlyForDeleteConflicts() {
        for action in [DeleteConflictAction.keep, .delete] {
            let resolution = RawFileResolution(path: "text.ts", hunks: [], reasoning: "r", action: action)
            #expect(checkResolutions(response([resolution]), [conflicted("text.ts")]).resolutions.isEmpty)
            let deleted = FileConflictContext(path: "text.ts", hunks: [], deletedSide: .theirs)
            #expect(checkResolutions(response([resolution]), [deleted]).resolutions.map(\.deleteConflictAction) == [action])
        }
    }

    @Test("fails a file without its original content, at the reassembly stage")
    func missingRawContent() {
        let checked = checkResolutions(
            response([RawFileResolution(path: "a.ts", hunks: hunks("x"), reasoning: "r")]),
            [makeFile("a.ts", "a", "b")]
        )
        #expect(checked.resolutions.isEmpty)
        #expect(checked.unresolved.map(\.stage) == [.reassembleResponse])
    }

    @Test("never reports a file as resolved while it still has conflict markers")
    func leftoverMarkers() {
        let file = conflicted("a.ts")

        // A single marker is enough to reject the file.
        for marker in ["<<<<<<< HEAD", ">>>>>>> feature", "<<<<<<<", ">>>>>>>\u{2003}x"] {
            let resolution = RawFileResolution(path: "a.ts", hunks: hunks("merged\n\(marker)"), reasoning: "r")
            let checked = checkResolutions(response([resolution]), [file])
            #expect(checked.resolutions.isEmpty)
            #expect(checked.unresolved.map(\.stage) == [.reassembleResponse])
        }

        // A marker outside the file's blocks stays in the file too.
        var stray = file
        stray.rawContent = (file.rawContent ?? "") + "\n<<<<<<< leftover"
        #expect(checkResolutions(response([RawFileResolution(path: "a.ts", hunks: hunks("merged"), reasoning: "r")]), [stray]).resolutions.isEmpty)

        // Separator lines alone are ordinary text (a Markdown heading).
        let heading = RawFileResolution(path: "a.ts", hunks: hunks("Title\n======="), reasoning: "r")
        #expect(checkResolutions(response([heading]), [file]).resolutions.count == 1)
    }

    @Test("matches a path the model changed to the one file it reads as", arguments: [
        NamedCase("surrounding spaces", (model: "  src/file.ts  ", file: "src/file.ts")),
        NamedCase("Windows separators", (model: "src\\lib\\file.ts", file: "src/lib/file.ts")),
        NamedCase("a leading ./", (model: "./src/file.ts", file: "src/file.ts")),
        NamedCase("doubled separators", (model: "src//lib///file.ts", file: "src/lib/file.ts")),
        NamedCase("a backslash in the name", (model: "src/a/b.ts", file: "src/a\\b.ts")),
        NamedCase("a backtick the prompt dropped", (model: "src/file.ts", file: "src/fi`le.ts")),
        NamedCase("a leading space the model trimmed", (model: "notes.md", file: " notes.md")),
        NamedCase("a trailing space the model trimmed", (model: "notes.md", file: "notes.md ")),
        NamedCase("composed accents", (model: "caf\u{E9}.ts", file: "cafe\u{301}.ts")),
    ])
    func normalizedPaths(_ testCase: NamedCase<(model: String, file: String)>) {
        let checked = checkResolutions(
            response([RawFileResolution(path: testCase.value.model, hunks: hunks("merged"), reasoning: "r")]),
            [conflicted(testCase.value.file)]
        )
        // Resolved under the file's own path, never the model's.
        #expect(checked.resolutions.map { Array($0.path.unicodeScalars) } == [Array(testCase.value.file.unicodeScalars)])
    }

    @Test("matches the exact path first, and never guesses between files that read the same")
    func ambiguousPaths() {
        let files = [conflicted("a/b.ts"), conflicted("a\\b.ts")]
        let exact = checkResolutions(
            response([
                RawFileResolution(path: "a\\b.ts", hunks: hunks("backslash"), reasoning: "r"),
                RawFileResolution(path: "a/b.ts", hunks: hunks("slash"), reasoning: "r"),
            ]),
            files
        )
        #expect(exact.resolutions.map(\.resolvedContent) == ["a\nslash\nb", "a\nbackslash\nb"])

        let guessed = checkResolutions(response([RawFileResolution(path: "./a/b.ts", hunks: hunks("x"), reasoning: "r")]), files)
        #expect(guessed.resolutions.isEmpty)
        #expect(guessed.unresolved.map(\.path) == ["a/b.ts", "a\\b.ts"])
    }
}

// MARK: extractSymbols

@Suite("extractSymbols")
struct ExtractSymbolsTests {
    @Test("extracts exports from hunk content")
    func exports() {
        let symbols = extractSymbols(makeFile("utils.ts", "export function foo() {}", "export const bar = 1"))
        #expect(symbols.exports.contains("foo"))
        #expect(symbols.exports.contains("bar"))
    }

    @Test("extracts all export kinds")
    func allExportKinds() {
        let file = makeFile(
            "types.ts",
            [
                "export class MyClass {}", "export interface IMyInterface {}", "export type MyType = string",
                "export enum MyEnum {}", "export let myLet = 1",
            ].joined(separator: "\n"),
            ""
        )
        let exports = extractSymbols(file).exports
        #expect(exports.contains("MyClass"))
        #expect(exports.contains("IMyInterface"))
        #expect(exports.contains("MyType"))
        #expect(exports.contains("MyEnum"))
        #expect(exports.contains("myLet"))
    }

    @Test("extracts import paths and named references")
    func namedImports() {
        let symbols = extractSymbols(makeFile("app.ts", "import { foo, bar as baz } from '../utils'", ""))
        #expect(symbols.importPaths.contains("../utils"))
        #expect(symbols.references.contains("foo"))
        #expect(symbols.references.contains("bar"))
        #expect(!symbols.references.contains("baz"), "alias should not be treated as a reference")
    }

    @Test("extracts default import references")
    func defaultImport() {
        let symbols = extractSymbols(makeFile("consumer.ts", "import React from 'react'", ""))
        #expect(symbols.importPaths.contains("react"))
        #expect(symbols.references.contains("React"))
    }

    @Test("extracts extends/implements/instanceof/new/typeof references")
    func keywordReferences() {
        let references = extractSymbols(
            makeFile(
                "child.ts",
                "class Child extends BaseClass implements IFoo {}",
                "const x = new Widget()\nif (a instanceof Handler) {}\ntype T = typeof Config"
            )
        ).references
        #expect(references.contains("BaseClass"))
        #expect(references.contains("IFoo"))
        #expect(references.contains("Widget"))
        #expect(references.contains("Handler"))
        #expect(references.contains("Config"))
    }

    @Test("scans base content when present")
    func baseContent() {
        #expect(extractSymbols(makeFile("a.ts", "", "", baseContent: "export function fromBase() {}")).exports.contains("fromBase"))
    }

    @Test("scans context lines")
    func contextLines() {
        let symbols = extractSymbols(
            makeFile("b.ts", "", "", contextBefore: "import { ctxBefore } from './dep'", contextAfter: "export const ctxAfter = 1")
        )
        #expect(symbols.references.contains("ctxBefore"))
        #expect(symbols.exports.contains("ctxAfter"))
    }

    @Test("returns empty sets for a file with no symbols")
    func noSymbols() {
        let symbols = extractSymbols(makeFile("readme.md", "plain text", "other text"))
        #expect(symbols.exports.isEmpty)
        #expect(symbols.importPaths.isEmpty)
        #expect(symbols.references.isEmpty)
    }

    @Test("extracts namespace imports (import * as X)")
    func namespaceImport() {
        let symbols = extractSymbols(makeFile("app.ts", "import * as React from 'react'", ""))
        #expect(symbols.importPaths.contains("react"))
        #expect(symbols.references.contains("React"))
    }

    @Test("extracts combined default + named imports")
    func defaultAndNamed() {
        let symbols = extractSymbols(makeFile("app.ts", "import React, { useState, useEffect } from 'react'", ""))
        #expect(symbols.importPaths.contains("react"))
        #expect(symbols.references.contains("React"))
        #expect(symbols.references.contains("useState"))
        #expect(symbols.references.contains("useEffect"))
    }

    @Test("extracts type-only imports")
    func typeOnlyImports() {
        let symbols = extractSymbols(makeFile("types.ts", "import type { Foo, Bar } from './models'", ""))
        #expect(symbols.importPaths.contains("./models"))
        #expect(symbols.references.contains("Foo"))
        #expect(symbols.references.contains("Bar"))
    }

    @Test("strips inline type keyword from named imports")
    func inlineType() {
        let references = extractSymbols(makeFile("consumer.ts", "import { type Foo, bar } from './lib'", "")).references
        #expect(references.contains("Foo"), #"should extract Foo without "type" prefix"#)
        #expect(references.contains("bar"))
    }
}

// MARK: createDependencyAwareChunks

@Suite("createDependencyAwareChunks")
struct DependencyAwareChunksTests {
    @Test("returns all files in a single chunk when count <= targetSize")
    func singleChunk() {
        let chunks = createDependencyAwareChunks([makeFile("a.ts", "", ""), makeFile("b.ts", "", "")], 5)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 2)
    }

    @Test("groups files that import from each other")
    func groupsImports() throws {
        let fileA = makeFile("src/utils.ts", "export function helper() {}", "")
        let fileB = makeFile("src/app.ts", "import { helper } from './utils'", "")
        let fileC = makeFile("src/unrelated.ts", "const x = 1", "")

        let chunkPaths = paths(createDependencyAwareChunks([fileA, fileB, fileC], 2))

        // A and B are in the same chunk.
        let chunkWithA = try #require(chunkPaths.first { $0.contains("src/utils.ts") })
        #expect(chunkWithA.contains("src/app.ts"), "utils and app should be grouped")

        // C is separate.
        let chunkWithC = try #require(chunkPaths.first { $0.contains("src/unrelated.ts") })
        #expect(!chunkWithC.contains("src/utils.ts"), "unrelated should not be with utils")
    }

    @Test("groups files that share exported/referenced symbols")
    func groupsSharedSymbols() throws {
        let chunkPaths = paths(
            createDependencyAwareChunks(
                [
                    makeFile("a.ts", "export class MyService {}", ""),
                    makeFile("b.ts", "", "const s = new MyService()"),
                    makeFile("c.ts", "const y = 2", ""),
                ],
                2
            )
        )
        let chunkWithA = try #require(chunkPaths.first { $0.contains("a.ts") })
        #expect(chunkWithA.contains("b.ts"), "a and b share MyService reference")
    }

    @Test("splits large dependency groups beyond target size")
    func splitsLargeGroups() {
        // A group of 6 files all exporting and referencing the same symbol.
        let files = (0..<6).map { makeFile("file\($0).ts", "export function sharedFn() {}", "const x = new sharedFn()") }

        let chunks = createDependencyAwareChunks(files, 3)

        // At least 2 chunks, since a group of 6 exceeds the target of 3.
        #expect(chunks.count >= 2)
        // No chunk exceeds the target size.
        for chunk in chunks {
            #expect(chunk.count <= 3, "chunk has \(chunk.count) files, expected <= 3")
        }
    }

    @Test("bin-packs small independent groups")
    func binPacks() {
        // 4 independent files, target size 2.
        let chunks = createDependencyAwareChunks(
            [
                makeFile("a.ts", "const a = 1", ""), makeFile("b.ts", "const b = 2", ""),
                makeFile("c.ts", "const c = 3", ""), makeFile("d.ts", "const d = 4", ""),
            ],
            2
        )
        // 2 chunks of 2.
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 2)
        #expect(chunks[1].count == 2)
    }

    @Test("every input file appears in exactly one chunk")
    func everyFileOnce() {
        let files = (0..<25).map { makeFile("file\($0).ts", "const x\($0) = \($0)", "") }

        let allPaths = createDependencyAwareChunks(files, 5).flatMap { $0.map(\.path) }

        #expect(allPaths.count == 25)
        #expect(Set(allPaths).count == 25, "no duplicates")
    }

    @Test("does not false-positive group files with short basenames")
    func shortBasenames() throws {
        // "e.ts" (base name "e") and "database.ts" are grouped only because
        // database imports from '../e', a full path segment match.
        let chunkPaths = paths(
            createDependencyAwareChunks(
                [
                    makeFile("src/e.ts", "export const val = 1", ""),
                    makeFile("src/database.ts", "import { something } from '../e'", ""),
                    makeFile("src/other.ts", "const x = 1", ""),
                    makeFile("src/third.ts", "const y = 2", ""),
                ],
                2
            )
        )
        let chunkWithE = try #require(chunkPaths.first { $0.contains("src/e.ts") })
        #expect(chunkWithE.contains("src/database.ts"), "e.ts and database.ts should be grouped (database imports from e)")

        // Now verify that a different import path does not match.
        let chunks2 = createDependencyAwareChunks(
            [
                makeFile("src/e.ts", "export const val = 1", ""),
                makeFile("src/database.ts", "import { something } from '../components'", ""),
                makeFile("src/api.ts", "import { thing } from '@sentry/error-reporting'", ""),
                makeFile("src/misc.ts", "const z = 3", ""),
            ],
            2
        )
        // Split into 2 chunks of 2, not collapsed into fewer.
        #expect(chunks2.count == 2, "unrelated files should not be grouped")
    }

    @Test("does not group unrelated index.ts files together")
    func unrelatedIndexFiles() {
        let chunks = createDependencyAwareChunks(
            [
                makeFile("src/auth/index.ts", "import { User } from '../models/user'", ""),
                makeFile("src/ui/index.ts", "import { Button } from './button'", ""),
                makeFile("src/api/index.ts", "export const api = {}", ""),
            ],
            2
        )
        // Unrelated despite sharing the base name "index".
        #expect(chunks.count >= 2, "unrelated index.ts files should not all be grouped together")
    }

    @Test("handles group.length exactly equal to targetSize")
    func groupEqualToTarget() {
        // 3 files all referencing the same symbol, target size 3.
        let chunks = createDependencyAwareChunks(
            [
                makeFile("a.ts", "export class Shared {}", ""),
                makeFile("b.ts", "", "const x = new Shared()"),
                makeFile("c.ts", "", "const y = new Shared()"),
                makeFile("d.ts", "const standalone = 1", ""),
            ],
            3
        )
        #expect(Set(chunks.flatMap { $0.map(\.path) }).count == 4, "all files present")
        // The group of 3 takes the split path (>= targetSize) and d.ts is separate.
        for chunk in chunks {
            #expect(chunk.count <= 3, "chunk has \(chunk.count) files, expected <= 3")
        }
    }

    @Test("packs chunks by conflict size as well as file count, a file too large for any chunk on its own")
    func packsBySize() {
        // Ours (starting with `ours`) and theirs of `size` units in all.
        func sized(_ path: String, _ size: Int, ours: String = "") -> FileConflictContext {
            makeFile(path, ours + String(repeating: "y", count: size / 2 - ours.count), String(repeating: "z", count: size - size / 2))
        }
        let files = [sized("a.ts", 40), sized("b.ts", 50), sized("c.ts", 30), sized("big.ts", 150), sized("d.ts", 20)]
        #expect(files.map(conflictContentSize) == [40, 50, 30, 150, 20])

        #expect(paths(createDependencyAwareChunks(files, 10, maxContentSize: 100)) == [["a.ts", "b.ts"], ["c.ts"], ["big.ts"], ["d.ts"]])
        // Within both limits, everything goes in one request.
        #expect(paths(createDependencyAwareChunks(files, 10, maxContentSize: 290)) == [files.map(\.path)])

        // A dependency group too large for one chunk is split in order.
        let group = (0..<4).map { sized("g\($0).ts", 100, ours: "export function shared\($0)() {} new shared\(($0 + 1) % 4)()\n") }
        #expect(paths(createDependencyAwareChunks(group + [sized("e.ts", 10)], 10, maxContentSize: 250)) == [["g0.ts", "g1.ts"], ["g2.ts", "g3.ts"], ["e.ts"]])
    }
}

// MARK: selectReferencedContext

private func makeResolutionContext(
    pullRequests: [ConflictContextPullRequest] = [],
    ourCommits: [ConflictContextCommit] = [],
    theirCommits: [ConflictContextCommit] = []
) -> ConflictResolutionContext {
    ConflictResolutionContext(
        ourLabel: "main",
        theirLabel: "feature",
        files: [],
        pullRequests: pullRequests,
        ourCommits: ourCommits,
        theirCommits: theirCommits
    )
}

private func ctxCommit(_ sha: String, _ summary: String, isOnRemote: Bool = true) -> ConflictContextCommit {
    ConflictContextCommit(
        sha: sha.lowercased().padding(toLength: 40, withPad: "0", startingAt: 0),
        shortSha: String(sha.prefix(7)),
        summary: summary,
        isOnRemote: isOnRemote
    )
}

private func ctxPr(_ number: Int, _ title: String) -> ConflictContextPullRequest {
    ConflictContextPullRequest(number: number, title: title, body: "")
}

@Suite("selectReferencedContext")
struct SelectReferencedContextTests {
    @Test("resolves pull request references against the gathered context")
    func pullRequests() {
        let context = makeResolutionContext(pullRequests: [ctxPr(20, "Add greetings")])
        let selected = selectReferencedContext([AIConflictReference(type: .pullRequest, id: "20")], context)
        #expect(selected == [.pullRequest(ctxPr(20, "Add greetings"))])
    }

    @Test("resolves commit references by full and abbreviated SHA")
    func commits() {
        let commit = ctxCommit("abc1234def", "Fix bug")
        let context = makeResolutionContext(theirCommits: [commit])

        #expect(selectReferencedContext([AIConflictReference(type: .commit, id: "abc1234")], context) == [.commit(commit)])
        #expect(selectReferencedContext([AIConflictReference(type: .commit, id: commit.sha)], context).count == 1)
    }

    @Test("refuses to resolve short or ambiguous commit prefixes")
    func shortOrAmbiguous() {
        let context = makeResolutionContext(theirCommits: [ctxCommit("abc1234aaa", "First"), ctxCommit("abc1234bbb", "Second")])

        // Too short to prefix-match.
        #expect(selectReferencedContext([AIConflictReference(type: .commit, id: "abc")], context).isEmpty)
        // A 7-character prefix shared by two commits is ambiguous, so it's dropped.
        #expect(selectReferencedContext([AIConflictReference(type: .commit, id: "abc1234")], context).isEmpty)
    }

    @Test("promotes a merge commit to its pull request, de-duplicating direct citations")
    func promotesMergeCommits() {
        let context = makeResolutionContext(
            pullRequests: [ctxPr(20, "Add greetings")],
            theirCommits: [ctxCommit("mergesha123", "Add greetings (#20)")]
        )

        // Citing the merge commit alone resolves to the promoted pull request...
        #expect(
            selectReferencedContext([AIConflictReference(type: .commit, id: "mergesha123")], context)
                == [.pullRequest(ctxPr(20, "Add greetings"))]
        )

        // ...and citing both the pull request and its merge commit yields one entry.
        #expect(
            selectReferencedContext(
                [AIConflictReference(type: .pullRequest, id: "20"), AIConflictReference(type: .commit, id: "mergesha123")],
                context
            ) == [.pullRequest(ctxPr(20, "Add greetings"))]
        )
    }

    @Test("keeps a merge commit as a commit when its PR was not gathered")
    func keepsUngatheredMergeCommit() {
        let commit = ctxCommit("mergesha123", "Add greetings (#20)")
        let context = makeResolutionContext(theirCommits: [commit])
        #expect(selectReferencedContext([AIConflictReference(type: .commit, id: "mergesha123")], context) == [.commit(commit)])
    }
}

@Suite("fallbackReferencedContext")
struct FallbackReferencedContextTests {
    @Test("prefers the incoming pull request over commits")
    func prefersPullRequests() {
        let context = makeResolutionContext(
            pullRequests: [ctxPr(20, "Add greetings")],
            theirCommits: [ctxCommit("abc1234", "Add greetings")]
        )
        #expect(fallbackReferencedContext(context) == [.pullRequest(ctxPr(20, "Add greetings"))])
    }

    @Test("returns empty when there are no commits or pull requests")
    func empty() {
        #expect(fallbackReferencedContext(makeResolutionContext()).isEmpty)
    }

    @Test("treats WIP, fixup, squash, and amend summaries as noise, by ASCII case and word")
    func lowSignalSummaries() {
        for noise in ["WIP", "wip: try", "fixup! x", "Squash! y", "AMEND", "Merge pull request #1"] {
            let context = makeResolutionContext(theirCommits: [ctxCommit("1111111", noise), ctxCommit("2222222", "Real work")])
            #expect(fallbackReferencedContext(context) == [.commit(ctxCommit("2222222", "Real work"))], "\(noise)")
        }
        for meaningful in ["wiped caches", "Amendment to docs", "Merged-in fix", "w\u{131}p"] {
            let context = makeResolutionContext(theirCommits: [ctxCommit("1111111", meaningful)])
            #expect(fallbackReferencedContext(context) == [.commit(ctxCommit("1111111", meaningful))], "\(meaningful)")
        }
    }
}

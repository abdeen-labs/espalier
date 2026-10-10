// Ported from desktop/app/test/unit/copilot-conflict-resolution-test.ts

@testable import AIKit
import Foundation
import Testing

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
    _ pattern: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("Expected an AIValidationError matching \(pattern)", sourceLocation: sourceLocation)
    } catch let error as AIValidationError {
        #expect(
            error.message.range(of: pattern, options: .regularExpression) != nil,
            "\(error.message) doesn't match \(pattern)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record("Expected an AIValidationError, got \(error)", sourceLocation: sourceLocation)
    }
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
        expectValidationError("invalid JSON") { _ = try parseAIConflictResolution("not json") }
    }

    @Test("throws on non-object payload")
    func nonObject() {
        expectValidationError("expected an object") { _ = try parseAIConflictResolution(#""string""#) }
    }

    @Test("throws on missing resolutions array")
    func missingResolutions() {
        expectValidationError(#""resolutions" must be an array"#) { _ = try parseAIConflictResolution(#"{"foo":"bar"}"#) }
    }

    @Test("throws on empty resolutions array")
    func emptyResolutions() {
        expectValidationError(#""resolutions" must not be empty"#) {
            _ = try parseAIConflictResolution(#"{"resolutions":[]}"#)
        }
    }

    @Test("throws on missing path")
    func missingPath() {
        let json = payload([["hunks": [["resolvedContent": "c"]], "reasoning": "r"]])
        expectValidationError(#""path" at index 0"#) { _ = try parseAIConflictResolution(json) }
    }

    @Test("throws on empty path")
    func emptyPath() {
        let json = payload([["path": "  ", "hunks": [["resolvedContent": "c"]], "reasoning": "r"]])
        expectValidationError(#""path" at index 0"#) { _ = try parseAIConflictResolution(json) }
    }

    @Test("throws on missing hunks")
    func missingHunks() {
        expectValidationError(#""hunks" at index 0 must be an array"#) {
            _ = try parseAIConflictResolution(#"{"resolutions":[{"path":"a.ts","reasoning":"r"}]}"#)
        }
    }

    @Test("throws on empty hunks array")
    func emptyHunks() {
        let json = payload([["path": "a.ts", "hunks": [], "reasoning": "r"]])
        expectValidationError(#""hunks" at index 0 must not be empty"#) { _ = try parseAIConflictResolution(json) }
    }

    @Test("throws on missing reasoning")
    func missingReasoning() {
        let json = payload([["path": "a.ts", "hunks": [["resolvedContent": "c"]]]])
        expectValidationError(#""reasoning" at index 0"#) { _ = try parseAIConflictResolution(json) }
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

    @Test("throws on truncated conflict markers (opening + separator without closing)")
    func truncatedMarkers() {
        let json = payload([makeResolution("a.ts", "<<<<<<< HEAD\nours\n=======\ntheirs but truncated", "truncated")])
        expectValidationError("still contains conflict markers") { _ = try parseAIConflictResolution(json) }
    }

    @Test("parses JSON block followed by another code block")
    func followedByAnotherBlock() throws {
        let content = "```json\n" + payload([makeResolution("a.ts", "fixed", "merged")])
            + "\n```\n\nYou can verify with:\n```bash\nnpm test\n```"
        #expect(try parseAIConflictResolution(content).resolutions[0].path == "a.ts")
    }

    @Test("trims whitespace from path values")
    func trimsPaths() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("  src/file.ts  ", "content", "reason")]))
        #expect(result.resolutions[0].path == "src/file.ts")
    }

    @Test("normalizes Windows-style backslash separators")
    func backslashes() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("src\\lib\\file.ts", "content", "reason")]))
        #expect(result.resolutions[0].path == "src/lib/file.ts")
    }

    @Test("strips leading ./ from paths")
    func leadingDotSlash() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("./src/file.ts", "content", "reason")]))
        #expect(result.resolutions[0].path == "src/file.ts")
    }

    @Test("collapses redundant path separators")
    func redundantSeparators() throws {
        let result = try parseAIConflictResolution(payload([makeResolution("src//lib///file.ts", "content", "reason")]))
        #expect(result.resolutions[0].path == "src/lib/file.ts")
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

    @Test("throws when action resolution has empty reasoning")
    func actionEmptyReasoning() {
        let json = payload([["path": "a.ts", "hunks": [], "reasoning": "", "action": "keep"]])
        expectValidationError("reasoning.*must be a non-empty string") { _ = try parseAIConflictResolution(json) }
    }

    @Test("finds conflict markers after any JavaScript line terminator")
    func markersAfterLineTerminators() {
        for content in [
            "x\r<<<<<<< a\r=======\r>>>>>>> b", "<<<<<<<\n=======", "x\u{2028}<<<<<<< a\u{2029}=======",
        ] {
            let json = payload([makeResolution("a.ts", content, "r")])
            expectValidationError("still contains conflict markers") { _ = try parseAIConflictResolution(json) }
        }
        for content in ["<<<<<<<x\n=======", " <<<<<<< a\n=======", "<<<<<<< a\n========", "<<<<<<< a\n=======x"] {
            #expect(throws: Never.self, "\(content.debugDescription)") {
                _ = try parseAIConflictResolution(payload([makeResolution("a.ts", content, "r")]))
            }
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

// MARK: validateResolutionPaths

@Suite("validateResolutionPaths")
struct ValidateResolutionPathsTests {
    @Test("validates hunk count for regular resolutions alongside action files")
    func validatesRegularCounts() {
        let resolutions = [
            RawFileResolution(path: "text.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "merged"),
            RawFileResolution(path: "deleted.ts", hunks: [], reasoning: "keep it", action: .keep),
        ]
        let expectedFiles = [makeFile("text.ts", "a", "b"), FileConflictContext(path: "deleted.ts", hunks: [], deletedSide: .theirs)]
        #expect(throws: Never.self) { try validateResolutionPaths(resolutions, expectedFiles) }
    }

    @Test("still catches wrong hunk count for non-action resolutions")
    func wrongCount() {
        let resolutions = [
            RawFileResolution(
                path: "text.ts",
                hunks: [HunkResolution(resolvedContent: "x"), HunkResolution(resolvedContent: "y")],
                reasoning: "merged"
            ),
        ]
        expectValidationError(#"2 hunk\(s\).*expected 1"#) {
            try validateResolutionPaths(resolutions, [makeFile("text.ts", "a", "b")])
        }
    }

    @Test("rejects unexpected, duplicate, and missing paths")
    func pathSets() {
        let expected = [makeFile("a.ts", "a", "b"), makeFile("b.ts", "a", "b")]
        let a = RawFileResolution(path: "a.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "r")
        let b = RawFileResolution(path: "b.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "r")
        let c = RawFileResolution(path: "c.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "r")
        expectValidationError("unexpected file: c.ts") { try validateResolutionPaths([a, c], expected) }
        expectValidationError("duplicate file paths") { try validateResolutionPaths([a, a, b], expected) }
        expectValidationError("did not return resolutions for: b.ts") { try validateResolutionPaths([a], expected) }
    }

    @Test("compares paths by code units, as JavaScript does")
    func exactPaths() {
        let composed = RawFileResolution(path: "caf\u{E9}.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "r")
        expectValidationError("unexpected file") {
            try validateResolutionPaths([composed], [makeFile("cafe\u{301}.ts", "a", "b")])
        }
    }

    @Test("accepts an action only for a delete-vs-modify conflict")
    func actionsOnlyForDeleteConflicts() {
        let keep = RawFileResolution(path: "text.ts", hunks: [], reasoning: "keep it", action: .keep)
        expectValidationError(#"action for "text.ts", which is not a delete-vs-modify conflict"#) {
            try validateResolutionPaths([keep], [makeFile("text.ts", "a", "b")])
        }
        let delete = RawFileResolution(path: "text.ts", hunks: [], reasoning: "drop it", action: .delete)
        expectValidationError("not a delete-vs-modify conflict") {
            try validateResolutionPaths([delete], [makeFile("text.ts", "a", "b")])
        }
        #expect(throws: Never.self) {
            try validateResolutionPaths([keep], [FileConflictContext(path: "text.ts", hunks: [], deletedSide: .theirs)])
        }
    }
}

// MARK: reassembleResolutions

@Suite("reassembleResolutions")
struct ReassembleResolutionsTests {
    @Test("handles mixed action and text resolutions")
    func mixed() throws {
        let rawContent = ["line 1", "<<<<<<< HEAD", "our change", "=======", "their change", ">>>>>>> feature", "line 2"]
            .joined(separator: "\n")

        var textFile = makeFile("text.ts", "our change", "their change")
        textFile.rawContent = rawContent
        let result = try reassembleResolutions(
            [
                RawFileResolution(path: "text.ts", hunks: [HunkResolution(resolvedContent: "merged")], reasoning: "combined both"),
                RawFileResolution(path: "deleted.ts", hunks: [], reasoning: "keep file", action: .keep),
            ],
            [textFile, FileConflictContext(path: "deleted.ts", hunks: [], deletedSide: .ours)]
        )
        #expect(result.count == 2)

        // The text resolution was reassembled.
        #expect(result[0].deleteConflictAction == nil)
        #expect(result[0].resolvedContent.contains("merged"))

        // The action resolution was passed through.
        #expect(result[1].deleteConflictAction == .keep)
        #expect(result[1].resolvedContent == "")
    }

    @Test("fails when the original content is unavailable")
    func missingRawContent() {
        expectValidationError("original file content is unavailable") {
            _ = try reassembleResolutions(
                [RawFileResolution(path: "a.ts", hunks: [HunkResolution(resolvedContent: "x")], reasoning: "r")],
                [makeFile("a.ts", "a", "b")]
            )
        }
    }

    @Test("never reports a file as resolved while it still has conflict markers")
    func leftoverMarkers() {
        let rawContent = ["a", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "b"].joined(separator: "\n")
        var file = makeFile("a.ts", "ours", "theirs")
        file.rawContent = rawContent

        // A single marker is enough to reject the file.
        for marker in ["<<<<<<< HEAD", ">>>>>>> feature", "<<<<<<<", ">>>>>>>\u{2003}x"] {
            let resolution = RawFileResolution(path: "a.ts", hunks: [HunkResolution(resolvedContent: "merged\n\(marker)")], reasoning: "r")
            expectValidationError(#"resolved content of "a.ts" still contains conflict markers"#) {
                _ = try reassembleResolutions([resolution], [file])
            }
        }

        // A marker outside the file's blocks stays in the file too.
        var stray = file
        stray.rawContent = rawContent + "\n<<<<<<< leftover"
        expectValidationError("still contains conflict markers") {
            _ = try reassembleResolutions(
                [RawFileResolution(path: "a.ts", hunks: [HunkResolution(resolvedContent: "merged")], reasoning: "r")],
                [stray]
            )
        }

        // Separator lines alone are ordinary text (a Markdown heading).
        let heading = RawFileResolution(path: "a.ts", hunks: [HunkResolution(resolvedContent: "Title\n=======")], reasoning: "r")
        #expect(throws: Never.self) {
            _ = try reassembleResolutions([heading], [file])
        }
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

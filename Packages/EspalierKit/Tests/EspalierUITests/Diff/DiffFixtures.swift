// Fixed diffs for the diff view's tests and snapshots.

import AppKit
import EspalierCore
import Foundation
import GitKit
@testable import EspalierUI

/// Fixed diffs, parsed from patches with GitKit's parser.
enum DiffFixtures {
    /// A text diff from a patch's hunks.
    static func textDiff(_ patch: String) -> TextDiff {
        let raw = try! DiffParser().parse(patch)
        return TextDiff(
            text: raw.contents,
            hunks: raw.hunks,
            lineEndingsChange: nil,
            maxLineNumber: raw.maxLineNumber,
            hasHiddenBidiChars: raw.hasHiddenBidiChars
        )
    }

    /// A change to a Swift file: a modified block (two lines for two), an
    /// added run, a deleted line, and a second hunk.
    static let swiftPatch = """
    diff --git a/Sources/App/RepositoryLoader.swift b/Sources/App/RepositoryLoader.swift
    index 1111111..2222222 100644
    --- a/Sources/App/RepositoryLoader.swift
    +++ b/Sources/App/RepositoryLoader.swift
    @@ -10,7 +10,9 @@ struct RepositoryLoader {
         func load() throws -> Repository {
             let path = configuration.path
    -        let tip = repo.tip!
    -        return Repository(path: path, tip: tip)
    +        guard let tip = repo.tip else {
    +            return .empty
    +        }
    +        return Repository(path: path, tip: tip, isBare: false)
         }
    \u{20}
         func reload() {
    @@ -40,6 +42,5 @@ struct RepositoryLoader {
         func close() {
             cache.removeAll()
    -        // TODO: notify observers
             isOpen = false
         }
     }
    """

    static var swiftChange: TextDiff {
        textDiff(swiftPatch)
    }

    /// The old file's contents before `swiftPatch`: 45 lines, then 10 more
    /// below the diff (for expansion).
    static var swiftOldContents: [String] {
        var lines = (1...9).map { "// line \($0)" }
        lines += [
            "    func load() throws -> Repository {",
            "        let path = configuration.path",
            "        let tip = repo.tip!",
            "        return Repository(path: path, tip: tip)",
            "    }",
            "",
            "    func reload() {",
        ]
        lines += (19...41).map { "// line \($0)" }
        lines += [
            "    func close() {",
            "        cache.removeAll()",
            "        // TODO: notify observers",
            "        isOpen = false",
            "    }",
            "}",
        ]
        lines += (1...10).map { "// tail \($0)" }
        return lines
    }

    /// The new file's contents after `swiftPatch`: 46 lines, then the same
    /// 10 below the diff.
    static var swiftNewContents: [String] {
        var lines = (1...9).map { "// line \($0)" }
        lines += [
            "    func load() throws -> Repository {",
            "        let path = configuration.path",
            "        guard let tip = repo.tip else {",
            "            return .empty",
            "        }",
            "        return Repository(path: path, tip: tip, isBare: false)",
            "    }",
            "",
            "    func reload() {",
        ]
        lines += (19...41).map { "// line \($0)" }
        lines += [
            "    func close() {",
            "        cache.removeAll()",
            "        isOpen = false",
            "    }",
            "}",
        ]
        lines += (1...10).map { "// tail \($0)" }
        return lines
    }

    /// The Swift change with the dummy hunk at the bottom, as once its
    /// contents load.
    static var swiftChangeWithBottomHunk: TextDiff {
        let diff = swiftChange
        return getTextDiffWithBottomDummyHunk(diff, diff.hunks, swiftOldContents.count, swiftNewContents.count) ?? diff
    }

    /// Lines long enough to wrap, a tab, and wide characters.
    static let wrappingPatch = """
    diff --git a/README.md b/README.md
    index 1111111..2222222 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,3 @@
     # Espalier
    -Espalier is a native macOS client for Git and GitHub, written in Swift with SwiftUI and AppKit, that trains your branches along a wall.
    +Espalier is a native macOS app for Git and GitHub, written in Swift with SwiftUI and AppKit, that trains your branches neatly along a wall.
     \tIndented with a tab, then \u{65E5}\u{672C}\u{8A9E}\u{306E}\u{30C6}\u{30AD}\u{30B9}\u{30C8} and more text after it to wrap.
    """

    static var wrapping: TextDiff {
        textDiff(wrappingPatch)
    }

    /// A conflicted file's diff against HEAD: markers and their side added.
    static let conflictPatch = """
    diff --git a/Sources/App/Config.swift b/Sources/App/Config.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Config.swift
    +++ b/Sources/App/Config.swift
    @@ -1,4 +1,8 @@
     let name = "espalier"
    +<<<<<<< HEAD
     let timeout = 30
    +=======
    +let timeout = 60
    +>>>>>>> feature/longer-timeout
     let retries = 3
     let verbose = false
    """

    static var conflict: TextDiff {
        textDiff(conflictPatch)
    }

    /// A last line without a newline, changed to have one.
    static let noNewlinePatch = """
    diff --git a/notes.txt b/notes.txt
    index 1111111..2222222 100644
    --- a/notes.txt
    +++ b/notes.txt
    @@ -1,2 +1,2 @@
     first line
    -last line
    \\ No newline at end of file
    +last line
    """

    static var noNewline: TextDiff {
        textDiff(noNewlinePatch)
    }

    /// A diff with `count` lines changed in hunks of ten, for performance.
    static func large(lines count: Int) -> TextDiff {
        var patch = "diff --git a/big.txt b/big.txt\nindex 1111111..2222222 100644\n--- a/big.txt\n+++ b/big.txt\n"
        var oldLine = 1
        var newLine = 1
        var remaining = count
        while remaining > 0 {
            let changed = min(10, remaining)
            patch += "@@ -\(oldLine),\(changed + 2) +\(newLine),\(changed + 2) @@ func section\(oldLine)()\n"
            patch += " context before \(oldLine)\n"
            for index in 0..<changed {
                patch += "-    let value\(oldLine + index) = compute(\(oldLine + index)) // the old line\n"
            }
            for index in 0..<changed {
                patch += "+    let value\(newLine + index) = compute(\(newLine + index), cached: true) // the new line\n"
            }
            patch += " context after \(oldLine)\n"
            oldLine += changed + 12
            newLine += changed + 12
            remaining -= changed
        }
        return textDiff(patch)
    }

    /// A working directory file for the stub staging API.
    static func workingFile(_ path: String, selection: DiffSelection = .fromInitialSelection(.all)) -> WorkingDirectoryFileChange {
        WorkingDirectoryFileChange(path: path, status: .modified(), selection: selection)
    }
}

/// A test highlighter that proves the pipeline: Swift keywords, numbers,
/// strings, comments, and capitalized type names.
struct KeywordTestHighlighter: SyntaxHighlighter {
    static let keywords: Set<String> = ["func", "let", "var", "return", "guard", "else", "struct", "throws", "true", "false"]

    func tokens(for request: HighlightRequest) async -> [Int: [SyntaxToken]] {
        var result: [Int: [SyntaxToken]] = [:]
        for index in request.lineFilter where request.lines.indices.contains(index) {
            result[index] = Self.tokens(in: request.lines[index])
        }
        return result
    }

    static func tokens(in line: String) -> [SyntaxToken] {
        let units = Array(line.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0
        func isWordUnit(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
        }
        while index < units.count {
            let unit = units[index]
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2F {
                tokens.append(SyntaxToken(range: index..<units.count, style: .comment))
                break
            }
            if unit == 0x22 {
                var end = index + 1
                while end < units.count, units[end] != 0x22 {
                    end += 1
                }
                end = min(end + 1, units.count)
                tokens.append(SyntaxToken(range: index..<end, style: .string))
                index = end
                continue
            }
            if isWordUnit(unit) {
                var end = index
                while end < units.count, isWordUnit(units[end]) {
                    end += 1
                }
                let word = String(utf16CodeUnits: Array(units[index..<end]), count: end - index)
                if keywords.contains(word) {
                    tokens.append(SyntaxToken(range: index..<end, style: .keyword))
                } else if word.first?.isNumber == true {
                    tokens.append(SyntaxToken(range: index..<end, style: .number))
                } else if word.first?.isUppercase == true {
                    tokens.append(SyntaxToken(range: index..<end, style: .type))
                } else if end < units.count, units[end] == 0x28 {
                    tokens.append(SyntaxToken(range: index..<end, style: .function))
                }
                index = end
                continue
            }
            if "{}()[].,:=!?<>+-*/".utf16.contains(unit) {
                tokens.append(SyntaxToken(range: index..<(index + 1), style: .operatorOrPunctuation))
            }
            index += 1
        }
        return tokens
    }
}

/// Builds diff tables for tests and snapshots.
@MainActor
enum DiffTables {
    /// A controller showing `content`, laid out at `size`, its document
    /// built on the main actor.
    static func controller(_ content: DiffTableContent, size: CGSize = CGSize(width: 720, height: 360)) -> DiffTableController {
        let controller = DiffTableController()
        controller.buildsSynchronously = true
        controller.scrollView.frame = CGRect(origin: .zero, size: size)
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.apply(content)
        controller.scrollView.layoutSubtreeIfNeeded()
        return controller
    }
}

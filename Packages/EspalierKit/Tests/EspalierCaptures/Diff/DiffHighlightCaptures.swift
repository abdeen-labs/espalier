// A diff colored by the tree-sitter highlighter. Both versions of a file go
// through the diff's pipeline (`highlightContents`), as in the
// app, and the tokens go into the diff table, in light and dark (the theme
// is the same for every language).

import AppKit
import EspalierCore
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A change to one file: unchanged lines above and below, and one hunk
/// written as the diff shows it (" ", "-", and "+" lines; an empty line is
/// an empty context line).
struct HighlightedDiffChange {
    let path: String
    /// The hunk header's context (git's function line).
    let section: String
    let above: [String]
    let hunk: [String]
    let below: [String]

    init(path: String, section: String = "", above: [String] = [], hunk: String, below: [String] = []) {
        self.path = path
        self.section = section
        self.above = above
        self.hunk = hunk.components(separatedBy: "\n").map { $0.isEmpty ? " " : $0 }
        self.below = below
    }

    var oldLines: [String] {
        above + hunk.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) } + below
    }

    var newLines: [String] {
        above + hunk.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) } + below
    }

    var diff: TextDiff {
        let oldCount = hunk.filter { !$0.hasPrefix("+") }.count
        let newCount = hunk.filter { !$0.hasPrefix("-") }.count
        let start = above.count + 1
        let header = "@@ -\(start),\(oldCount) +\(start),\(newCount) @@" + (section.isEmpty ? "" : " \(section)")
        return DiffCaptureFixtures.textDiff(
            "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n"
                + ([header] + hunk).joined(separator: "\n")
        )
    }

    /// The tokens of both versions, as the diff's session gets them.
    func tokens() async -> FileTokens {
        let contents = DiffFileContents(fileID: path, oldLines: oldLines, newLines: newLines, canBeExpanded: true, isBinary: false)
        return await highlightContents(contents, path: path, oldPath: path, hunks: diff.hunks, tabSize: 4, highlighter: TreeSitterHighlighter())
    }

    /// A Swift change: a doc comment, a new parameter with a default,
    /// `async`, a `guard`, a string interpolation with a privacy argument.
    static let swift = HighlightedDiffChange(
        path: "Sources/App/RepositoryLoader.swift",
        section: "final class RepositoryLoader {",
        above: [
            "// Loads repositories from disk.",
            "",
            "import Foundation",
            "",
            "/// Loads a repository and its tip.",
            "@MainActor",
            "final class RepositoryLoader {",
        ],
        hunk: #"""
             private var cache: [String: Repository] = [:]
             var isOpen = false

        -    func load(_ path: String) throws -> Repository {
        -        let tip = try readTip(at: path)!
        +    /// Throws `LoadError.missingTip` for an empty repository.
        +    func load(_ path: String, bare: Bool = false) async throws -> Repository {
        +        guard let tip = try await readTip(at: path) else {
        +            throw LoadError.missingTip(path)
        +        }
                 cache[path] = Repository(path: path, tip: tip)
        -        return cache[path]!
        +        return Repository(path: path, tip: tip, isBare: bare)
             }

             func reload(retries: Int = 3) {
        -        print("Reloading \(cache.count) repositories")
        +        logger.info("Reloading \(cache.count) of \(retries, privacy: .public)")
                 isOpen = true
        """#,
        below: ["    }", "}"]
    )

    /// A Svelte change: a TypeScript script, markup with blocks and
    /// expressions, and a style.
    static let svelte = HighlightedDiffChange(
        path: "src/lib/TideList.svelte",
        above: [
            "<!-- The next tides at a station. -->",
            "<script lang=\"ts\">",
            "  import type { Tide } from \"./tides\";",
            "",
        ],
        hunk: #"""
           let { tides, limit = 5 }: { tides: Tide[]; limit?: number } = $props();
        -  let shown = tides.slice(0, limit);
        +  let expanded = $state(false);
        +  let shown = $derived(expanded ? tides : tides.slice(0, limit));
         </script>

         <ul class="tides">
           {#each shown as tide (tide.time)}
        -    <li>{tide.kind}: {tide.height} m</li>
        +    <li class:high={tide.kind === "high"}>{tide.kind}: {tide.height.toFixed(1)} m</li>
        +  {:else}
        +    <li class="empty">No tides today</li>
           {/each}
         </ul>
        +{#if tides.length > limit}
        +  <button onclick={() => (expanded = !expanded)}>Show {expanded ? "Fewer" : "All"}</button>
        +{/if}

         <style>
           .tides { margin: 0; padding-left: 1.5rem; }
        +  .high { font-weight: 600; color: #0a6; }
        """#,
        below: ["</style>"]
    )
}

@Suite("Diff highlighting", .captures, .hangGuard(minutes: 5)) @MainActor
struct DiffHighlightCaptures {
    private let area = "Diff"

    /// Captures `change` in the diff table, colored by the highlighter.
    private func capture(_ name: String, _ change: HighlightedDiffChange, height: CGFloat) async throws {
        let tokens = await change.tokens()
        try #require(!tokens.isEmpty)
        let content = DiffTableContent(fileID: change.path, diff: change.diff, tokens: tokens, tokensGeneration: 1)
        for appearance in CaptureAppearance.allCases {
            let scene = await DiffTableScene(content, size: CGSize(width: 720, height: height), appearance: appearance)
            EspalierCaptures.capture(named: name, area: area, appearances: [appearance]) { _ in
                scene.image()
            }
        }
    }

    @Test("Swift")
    func swift() async throws {
        try await capture("highlight-swift", HighlightedDiffChange.swift, height: 400)
    }

    @Test("Svelte")
    func svelte() async throws {
        try await capture("highlight-svelte", HighlightedDiffChange.svelte, height: 520)
    }
}

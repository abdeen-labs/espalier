// Ported from desktop/app/src/lib/copilot-conflict-resolution.ts (chunking)

import EspalierSupport
import Foundation

/// Symbols found in a file's conflict hunks, for dependency detection.
public struct ConflictFileSymbols: Sendable, Hashable {
    public var exports: Set<String>
    public var importPaths: Set<String>
    public var references: Set<String>
}

// JavaScript's `\s` and `\w`, for ICU patterns.
private let s = JSCompat.whitespace
private let w = "[A-Za-z0-9_]"

private let exportPattern = JSCompat.regex(
    "export\(s)+(?:function|const|let|class|interface|type|enum)\(s)+(\(w)+)"
)

// Matches all common import forms:
//   import { a, b } from 'x'
//   import X from 'x'
//   import * as X from 'x'
//   import X, { a, b } from 'x'
//   import type { a } from 'x'
private let importPattern = JSCompat.regex(
    #"import\#(s)+(?:type\#(s)+)?(?:(\*\#(s)+as\#(s)+\#(w)+)|(\#(w)+)\#(s)*,\#(s)*\{([^}]+)\}|\{([^}]+)\}|(\#(w)+))\#(s)+from\#(s)+['"]([^'"]+)['"]"#
)

private let referencePattern = JSCompat.regex(
    "(?:extends|implements|instanceof|new|typeof)\(s)+(\(w)+)"
)

private let namespacePrefix = JSCompat.regex(#"^\*\#(s)+as\#(s)+"#)
private let typePrefix = JSCompat.regex("^type\(s)+")
private let asSeparator = JSCompat.regex("\(s)+as\(s)+")

/// Extracts exported and imported symbols from a file's conflict hunks for
/// dependency detection. Scans all hunk sections (ours, theirs, base,
/// context) to find import paths, exported names, and referenced
/// identifiers.
///
/// Swift's `Set<String>` merges canonically equivalent names, which
/// JavaScript's `Set` keeps apart; `createDependencyAwareChunks` compares
/// them exactly.
public func extractSymbols(_ file: FileConflictContext) -> ConflictFileSymbols {
    let symbols = collectSymbols(file)
    return ConflictFileSymbols(
        exports: Set(symbols.exports),
        importPaths: Set(symbols.importPaths),
        references: Set(symbols.references)
    )
}

/// The symbols `extractSymbols` finds, in order, repeats included.
private func collectSymbols(_ file: FileConflictContext) -> (exports: [String], importPaths: [String], references: [String]) {
    var exports: [String] = []
    var importPaths: [String] = []
    var references: [String] = []

    var textParts: [String] = []
    for hunk in file.hunks {
        textParts.append(contentsOf: [hunk.oursContent, hunk.theirsContent, hunk.contextBefore, hunk.contextAfter])
        if let baseContent = hunk.baseContent {
            textParts.append(baseContent)
        }
    }
    let content = textParts.joined(separator: "\n")

    for match in JS.matchAll(content, exportPattern) {
        if let name = match[1] {
            exports.append(name)
        }
    }

    for match in JS.matchAll(content, importPattern) {
        // Group 6 is always the import path.
        if let path = match[6] {
            importPaths.append(path)
        }

        // Collect referenced names from whichever group matched.
        var parts: [String] = []
        if let namespace = match[1] {
            // import * as X: extract X.
            let asName = JSCompat.trim(JS.replaceFirst(namespace, namespacePrefix, with: ""))
            if !asName.isEmpty {
                parts.append(asName)
            }
        } else if let defaultName = match[2], let named = match[3] {
            // import Default, { named }: both.
            parts.append(defaultName)
            parts.append(contentsOf: JSCompat.split(named, ","))
        } else if let named = match[4] {
            // import { named }
            parts.append(contentsOf: JSCompat.split(named, ","))
        } else if let defaultName = match[5] {
            // import Default
            parts.append(defaultName)
        }

        for name in parts {
            let withoutType = JS.replaceFirst(JSCompat.trim(name), typePrefix, with: "")
            let trimmed = JSCompat.trim(JS.firstSplitComponent(withoutType, asSeparator))
            if !trimmed.isEmpty {
                references.append(trimmed)
            }
        }
    }

    for match in JS.matchAll(content, referencePattern) {
        if let name = match[1] {
            references.append(name)
        }
    }

    return (exports, importPaths, references)
}

private let fileExtension = JSCompat.regex(#"\.[^.]+\z"#)
private let importExtension = JSCompat.regex(#"\.[^./]+\z"#)
private let directoryPrefix = JSCompat.regex("^\(JSCompat.dot)*/")

/// An import path's base name: without its extension and directories.
private func importBaseName(_ path: String) -> String {
    JS.replaceFirst(JS.replaceFirst(path, importExtension, with: ""), directoryPrefix, with: "")
}

/// The most conflict content (`conflictContentSize`) one request carries:
/// as much as one file may have (`MaxConflictContentSize`), so a request is
/// never larger than the largest file the resolver accepts on its own.
public let MaxChunkConflictContentSize = MaxConflictContentSize

/// The size of a file's conflicts as `getHunkSkipReason` measures them: the
/// ours, base, and theirs content of every hunk, in UTF-16 code units.
func conflictContentSize(_ file: FileConflictContext) -> Int {
    file.hunks.reduce(0) { total, hunk in
        total + JS.length(hunk.oursContent) + JS.length(hunk.theirsContent) + JS.length(hunk.baseContent ?? "")
    }
}

/// Groups files that share dependencies into clusters using union-find,
/// then packs the clusters into chunks of at most `targetSize` files and
/// `maxContentSize` of conflict content (`conflictContentSize`); a single
/// file larger than that is a chunk of its own. Files that import from each
/// other or reference each other's exports stay in the same chunk so the
/// model can reason about cross-file coherence, unless their group is too
/// large for one chunk.
public func createDependencyAwareChunks(
    _ files: [FileConflictContext],
    _ targetSize: Int,
    maxContentSize: Int = MaxChunkConflictContentSize
) -> [[FileConflictContext]] {
    let sizes = files.map(conflictContentSize)
    if files.count <= targetSize, sizes.reduce(0, +) <= maxContentSize {
        return [files]
    }

    // Names are compared by code units, as JavaScript's `===` and `Set.has`
    // do.
    let fileSymbols = files.map { file in
        let symbols = collectSymbols(file)
        return (
            exports: symbols.exports.exactSet,
            importBaseNames: symbols.importPaths.map(importBaseName).exactSet,
            references: symbols.references.exactSet,
            baseName: ExactString(JS.replaceFirst(JS.replaceFirst(file.path, fileExtension, with: ""), directoryPrefix, with: ""))
        )
    }

    // Union-find.
    var parent = Array(files.indices)

    func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    func union(_ a: Int, _ b: Int) {
        let pa = find(a)
        let pb = find(b)
        if pa != pb {
            parent[pa] = pb
        }
    }

    for i in fileSymbols.indices {
        for j in fileSymbols.indices where j > i {
            let a = fileSymbols[i]
            let b = fileSymbols[j]

            // Match import paths by path-segment boundary, not bare
            // substring, to avoid false positives with short base names like
            // "e" or "api".
            let aImportsB = a.importBaseNames.contains(b.baseName)
            let bImportsA = b.importBaseNames.contains(a.baseName)

            let sharedSymbols = !a.exports.isDisjoint(with: b.references) || !b.exports.isDisjoint(with: a.references)

            if aImportsB || bImportsA || sharedSymbols {
                union(i, j)
            }
        }
    }

    // Collect dependency groups, in order of each group's first file.
    var groupRoots: [Int] = []
    var groups: [Int: [Int]] = [:]
    for i in files.indices {
        let root = find(i)
        if groups[root] == nil {
            groupRoots.append(root)
        }
        groups[root, default: []].append(i)
    }

    // Pack groups into chunks: large groups get split, small groups bin-pack.
    var result: [[FileConflictContext]] = []
    var currentBin: [Int] = []
    var currentSize = 0

    func flush() {
        if !currentBin.isEmpty {
            result.append(currentBin.map { files[$0] })
        }
        currentBin = []
        currentSize = 0
    }

    for root in groupRoots {
        let group = groups[root] ?? []
        let groupSize = group.reduce(0) { $0 + sizes[$1] }
        if group.count >= targetSize || groupSize > maxContentSize {
            // In order, as many files to a chunk as fit.
            flush()
            for index in group {
                if !currentBin.isEmpty, currentBin.count == targetSize || currentSize + sizes[index] > maxContentSize {
                    flush()
                }
                currentBin.append(index)
                currentSize += sizes[index]
            }
            flush()
        } else if currentBin.count + group.count > targetSize || currentSize + groupSize > maxContentSize {
            flush()
            currentBin = group
            currentSize = groupSize
        } else {
            currentBin += group
            currentSize += groupSize
        }
    }
    flush()

    return result
}

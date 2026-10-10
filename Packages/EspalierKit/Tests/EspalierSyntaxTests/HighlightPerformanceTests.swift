// How long highlighting takes. Color follows a diff within ~300 ms, so a
// whole 10,000-line file in Swift or TypeScript, every line asked for,
// highlights within 300 ms, even the first time (when the language's
// queries compile). Measured only in release builds, since debug builds
// compile tree-sitter's C unoptimized (about five times slower), so a
// plain `swift test` skips the suite and says so. To run it:
//
//     swift test -c release -j 4 --filter HighlightPerformanceTests

import EspalierSyntax
import Foundation
import Testing

#if DEBUG
private let isRelease = false
#else
private let isRelease = true
#endif

/// A synthetic file to highlight, named for the results.
struct SyntheticFile: Sendable, CustomTestStringConvertible {
    let grammar: String
    let lines: @Sendable () -> [String]
    let testDescription: String
}

/// The budget for one file, in milliseconds.
private let budget = 300.0

/// How long `body` takes, in milliseconds.
private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let duration = try ContinuousClock().measure(body)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The median of `values`.
private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

private func format(_ value: Double) -> String {
    String(format: "%.1f ms", value)
}

/// One file at a time, so their timings don't overlap.
@Suite(
    "Highlight performance",
    .serialized,
    .enabled(if: isRelease, "measured in release builds only: swift test -c release --filter HighlightPerformanceTests")
)
enum HighlightPerformanceTests {
    @Suite("Synthetic files")
    struct SyntheticFiles {
        /// Highlights all of the file's lines with three fresh engines
        /// (each compiling the language's queries first, as the first diff
        /// in a language does), then five times each, on one engine, for
        /// all lines, a 60-line window in the middle, and one near the top;
        /// checks the budget and prints the medians.
        @Test("10,000 lines highlight within 300 ms", arguments: [
            SyntheticFile(
                grammar: "swift",
                lines: { SyntheticSources.swift(lines: 10_000) },
                testDescription: "10,000 lines of Swift highlight within 300 ms"
            ),
            SyntheticFile(
                grammar: "typescript",
                lines: { SyntheticSources.typeScript(lines: 10_000) },
                testDescription: "10,000 lines of TypeScript highlight within 300 ms"
            ),
        ])
        func measure(_ file: SyntheticFile) throws {
            let lines = file.lines()
            let grammar = try #require(Grammars.grammar(id: file.grammar))
            let all = Set(lines.indices)
            let middle = Set((lines.count / 2)..<(lines.count / 2 + 60))
            let top = Set(100..<160)

            var firstRuns: [Double] = []
            for _ in 0..<3 {
                let fresh = SyntaxHighlightEngine()
                var ranges: [Int: [HighlightedRange]] = [:]
                firstRuns.append(try milliseconds {
                    ranges = try fresh.highlight(lines, grammar: grammar, lineFilter: all)
                })
                #expect(ranges.count > lines.count / 2)
            }
            let cold = median(firstRuns)

            let engine = SyntaxHighlightEngine()
            _ = try engine.highlight(lines, grammar: grammar, lineFilter: top)
            func medianTime(_ filter: Set<Int>) throws -> Double {
                var times: [Double] = []
                for _ in 0..<5 {
                    times.append(try milliseconds {
                        _ = try engine.highlight(lines, grammar: grammar, lineFilter: filter)
                    })
                }
                return median(times)
            }
            let warm = try medianTime(all)
            let window = try medianTime(middle)
            let near = try medianTime(top)
            print("Highlight performance: \(grammar.name), \(lines.count) lines: all lines \(format(warm)) (the first time, compiling the queries, \(format(cold))); lines \(lines.count / 2)–\(lines.count / 2 + 60) \(format(window)); lines 100–160 \(format(near))")
            #expect(warm < budget, "\(grammar.name): \(format(warm)) for all lines")
            #expect(cold < budget, "\(grammar.name): \(format(cold)) for the first time")
            #expect(window < budget && near < budget)
        }
    }

    @Suite("The first file in a language")
    struct FirstFile {
        /// Highlights all of a Swift file's lines with fresh engines, whose
        /// queries compile while the file parses, and, for comparison, with
        /// the queries compiled first (a one-line file) and the file after
        /// them; prints the medians of five runs each.
        @Test("the queries compile while the file parses", arguments: [1_000, 10_000])
        func compileOverlapsParse(_ lineCount: Int) throws {
            let lines = SyntheticSources.swift(lines: lineCount)
            let grammar = try #require(Grammars.grammar(id: "swift"))
            let all = Set(lines.indices)

            var compileOnly: [Double] = []
            var overlapped: [Double] = []
            var sequential: [Double] = []
            for _ in 0..<5 {
                let compiling = SyntaxHighlightEngine()
                compileOnly.append(try milliseconds {
                    _ = try compiling.highlight(["let a = 1"], grammar: grammar, lineFilter: [0])
                })
                let fresh = SyntaxHighlightEngine()
                overlapped.append(try milliseconds {
                    _ = try fresh.highlight(lines, grammar: grammar, lineFilter: all)
                })
                let first = SyntaxHighlightEngine()
                sequential.append(try milliseconds {
                    _ = try first.highlight(["let a = 1"], grammar: grammar, lineFilter: [0])
                    _ = try first.highlight(lines, grammar: grammar, lineFilter: all)
                })
            }
            print("Highlight performance: Swift, \(lineCount) lines, the first time: \(format(median(overlapped))) with the queries compiling during the parse; \(format(median(sequential))) compiling them first; compiling alone \(format(median(compileOnly)))")
            #expect(median(overlapped) < budget)
        }
    }
}

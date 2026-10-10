// The GitHub views' performance. Opt-in, because the numbers only mean
// something in a release build on a quiet machine:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --enable-testable-imports --filter GitHubPerformanceTests
//
// Every Markdown file in the repository the variable names parses (read in
// place); descriptions made of the repository's Markdown parse in 5 ms at
// 10 KB and in 50 ms at GitHub's largest (a body holds at most 65,536
// characters; descriptions parse off the main actor, reviews and comments
// on it); and the checks content for 200 checks with their steps, which
// the checks list and popover rebuild as checks change, builds in 2 ms.

import EspalierCore
import Foundation
import GitHubKit
import Testing
import TestSupport
@testable import EspalierUI

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The median of `samples`.
private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

/// The median time of `runs` runs of `body`, in milliseconds, after one
/// run to warm up.
private func measure(runs: Int, _ body: () -> Void) -> Double {
    body()
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        body()
        samples.append(milliseconds(.now - start))
    }
    return median(samples)
}

@Suite("GitHub performance", .enabled(if: perfRepository != nil), .serialized) @MainActor
struct GitHubPerformanceTests {
    /// The repository's Markdown files, outside `.git` and `node_modules`.
    private func markdownFiles(in root: String) -> [String] {
        let rootURL = URL(filePath: root, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var texts: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md", let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            texts.append(text)
        }
        return texts
    }

    @Test("the repository's Markdown parses; a 10 KB description in 5 ms, GitHub's largest in 50 ms")
    func markdown() throws {
        let root = try #require(perfRepository)
        let texts = markdownFiles(in: root)
        try #require(!texts.isEmpty, "No Markdown files in \(root)")

        var bytes = 0
        var blocks = 0
        let start = ContinuousClock.now
        for text in texts {
            bytes += text.utf8.count
            blocks += MarkdownDocument.parse(text, underlineLinks: false).blocks.count
        }
        let all = milliseconds(.now - start)

        // Descriptions of 10 KB and of GitHub's largest body: the
        // repository's Markdown, in whole lines, repeated as needed.
        func description(bytes target: Int) -> String {
            var text = ""
            var count = 0
            while true {
                for file in texts {
                    for line in file.split(separator: "\n", omittingEmptySubsequences: false) {
                        let lineBytes = line.utf8.count + 1
                        guard count + lineBytes <= target else {
                            return text
                        }
                        text += line
                        text += "\n"
                        count += lineBytes
                    }
                }
            }
        }
        let small = description(bytes: 10_000)
        let large = description(bytes: 65_536)
        let smallTime = measure(runs: 21) { _ = MarkdownDocument.parse(small) }
        let largeTime = measure(runs: 7) { _ = MarkdownDocument.parse(large) }

        print(String(
            format: "PERF Markdown: %d files, %d KB, %d blocks in %.1f ms; 10 KB median %.2f ms; 64 KB median %.1f ms",
            texts.count, bytes / 1_000, blocks, all, smallTime, largeTime
        ))
        #expect(smallTime <= 5)
        #expect(largeTime <= 50)
    }

    @Test("the content of 200 checks with their steps builds in 2 ms")
    func checks() throws {
        let workflows = (0..<10).map { index in
            APIWorkflowRun(
                id: 900 + index, workflowID: index, cancelURL: "", createdAt: "2026-10-06T09:00:00Z", logsURL: "",
                name: "Workflow \(index)", rerunURL: "", checkSuiteID: 100 + index, event: "pull_request"
            )
        }
        let conclusions: [APICheckConclusion?] = [.success, .success, .success, .failure, nil, .skipped, .neutral]
        let checks = (0..<200).map { index in
            let conclusion = conclusions[index % conclusions.count]
            let steps = (1...8).map { number in
                APIWorkflowJobStep(
                    name: "Step \(number)",
                    number: number,
                    status: conclusion == nil && number == 8 ? .inProgress : .completed,
                    conclusion: conclusion == nil && number == 8 ? nil : .success,
                    completedAt: "2026-10-06T09:0\(number):00Z",
                    startedAt: "2026-10-06T09:00:00Z"
                )
            }
            return RefCheck(
                id: 10_000 + index,
                name: "job \(index)",
                description: conclusion == nil ? "In progress" : "Successful in 3m 2s",
                status: conclusion == nil ? .inProgress : .completed,
                conclusion: conclusion,
                appName: "GitHub Actions",
                htmlURL: "https://github.com/octocat/hello/actions/runs/900/job/\(10_000 + index)",
                checkSuiteID: 100 + index % workflows.count,
                actionJobSteps: steps,
                actionsWorkflow: workflows[index % workflows.count]
            )
        }
        let combined = try #require(createCombinedCheckFromChecks(checks))
        var content: ChecksContent?
        let time = measure(runs: 21) {
            content = ChecksContent(check: combined, loaded: true, repository: GitHubFixtures.hello, pullRequestNumber: 142, rerunSupport: (true, true))
        }
        print(String(format: "PERF checks content, 200 checks of 8 steps in 10 workflows: median %.3f ms", time))
        #expect(content?.groups.count == 10)
        #expect(time <= 2)
    }
}

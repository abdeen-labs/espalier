// These run git through `git()` with a shell alias that writes scripted
// progress to standard error and to the Git LFS progress file.

import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Collects progress callbacks, and creates `marker` once Git LFS progress
/// arrives so the scripted git process can go on.
private final class ProgressRecorder: Sendable {
    private let results = Mutex<[GitProgressResult]>([])
    let marker: String

    init(marker: String) {
        self.marker = marker
    }

    var recorded: [GitProgressResult] { results.withLock { $0 } }

    func record(_ result: GitProgressResult) {
        results.withLock { $0.append(result) }
        if case .progress(let progress) = result, progress.details.title.hasPrefix("Downloading") {
            FileManager.default.createFile(atPath: marker, contents: Data())
        }
    }
}

/// A git invocation that runs `script` in a shell, as git would run a hook.
private func scriptedGit(_ script: String) -> [String] {
    ["-c", "alias.scripted=!f() { \(script) }; f", "scripted"]
}

/// Waits (up to 10 s) for `$MARKER` to exist.
private let waitForMarker = #"i=0; while [ ! -e "$MARKER" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done;"#

@Suite("executionOptionsWithProgress")
struct ProgressFromProcessTests {
    @Test("reports progress from standard error and the Git LFS progress file")
    func reportsProgress() async throws {
        let directory = try createTempDirectory()
        let recorder = ProgressRecorder(marker: "\(directory)/lfs-seen")
        let lfsPath = Mutex<String?>(nil)

        let script = #"""
            printf 'Receiving objects:  50%% (1/2)\r' >&2;
            printf '%s' "$GIT_LFS_PROGRESS" > lfs-path;
            printf 'download 1/1 5/10 a.bin\n' >> "$GIT_LFS_PROGRESS";
            """# + waitForMarker + #"""
            printf 'remote: hidden while LFS progress shows\n' >&2;
            printf 'Receiving objects: 100%% (2/2), done.' >&2;
            """#

        var options = GitExecutionOptions(env: ["MARKER": recorder.marker])
        options.trackLFSProgress = true
        let opts = await executionOptionsWithProgress(options, FetchProgressParser()) { result in
            recorder.record(result)
        }

        try await git(scriptedGit(script), directory, "scripted", options: opts)
        lfsPath.withLock { $0 = try? String(contentsOfFile: "\(directory)/lfs-path", encoding: .utf8) }

        // Every callback, including the unterminated last line, has run by
        // the time git() returns.
        let recorded = recorder.recorded
        let texts = recorded.map(\.text)
        #expect(texts.contains("Receiving objects:  50% (1/2)"))
        #expect(texts.last == "Receiving objects: 100% (2/2), done.")
        // Context lines are hidden while Git LFS progress shows.
        #expect(!texts.contains("remote: hidden while LFS progress shows"))
        #expect(recorded.allSatisfy { $0.isProgress })
        #expect(abs((recorded.last?.percent ?? 0) - 0.8) < 1e-12)

        // The progress file was named in the environment and removed when git
        // closed.
        let path = try #require(lfsPath.withLock { $0 })
        #expect(path.contains("Espalier-lfs-progress-"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("passes context lines through without Git LFS progress")
    func contextWithoutLFS() async throws {
        let directory = try createTempDirectory()
        let results = Mutex<[GitProgressResult]>([])

        let opts = await executionOptionsWithProgress(GitExecutionOptions(), PushProgressParser()) { result in
            results.withLock { $0.append(result) }
        }
        #expect(opts.env?["GIT_LFS_PROGRESS"] == nil)

        let script = #"""
            printf 'Writing objects:  50%% (1/2)\r' >&2;
            printf 'To /somewhere\r\n' >&2;
            printf '\n\n' >&2;
            printf 'Writing objects: 100%% (2/2), done.\n' >&2;
            printf 'stdout is not progress\n';
            """#
        try await git(scriptedGit(script), directory, "scripted", options: opts)

        let recorded = results.withLock { $0 }
        #expect(recorded.map(\.text) == [
            "Writing objects:  50% (1/2)",
            "To /somewhere",
            "Writing objects: 100% (2/2), done.",
        ])
        #expect(recorded.map(\.isProgress) == [true, false, true])
        // Context reports the last progress.
        #expect(recorded[1].percent == recorded[0].percent)
    }

    @Test("Filtering content ends Git LFS progress once it is done")
    func filteringContent() async throws {
        let directory = try createTempDirectory()
        let recorder = ProgressRecorder(marker: "\(directory)/lfs-seen")
        let parser = try GitProgressParser([
            ProgressStep(title: "Receiving objects", weight: 1),
            ProgressStep(title: "Filtering content", weight: 1),
        ])

        let script = #"""
            printf 'download 1/1 10/10 a.bin\n' >> "$GIT_LFS_PROGRESS";
            """# + waitForMarker + #"""
            printf 'hidden context\n' >&2;
            printf 'Filtering content:  50%% (1/2)\n' >&2;
            printf 'Filtering content: 100%% (2/2), done.\n' >&2;
            printf 'shown context\n' >&2;
            """#

        var options = GitExecutionOptions(env: ["MARKER": recorder.marker])
        options.trackLFSProgress = true
        let opts = await executionOptionsWithProgress(options, parser) { result in
            recorder.record(result)
        }
        try await git(scriptedGit(script), directory, "scripted", options: opts)

        // After the Git LFS progress, only the context that follows filtering.
        #expect(Array(recorder.recorded.map(\.text).dropFirst()) == ["shown context"])
    }

    @Test("reports progress from every process the options start, with one parser")
    func sharedParser() async throws {
        let directory = try createTempDirectory()
        let results = Mutex<[GitProgressResult]>([])
        let parser = try GitProgressParser([
            ProgressStep(title: "First", weight: 1),
            ProgressStep(title: "Second", weight: 1),
        ])
        let opts = await executionOptionsWithProgress(GitExecutionOptions(), parser) { result in
            results.withLock { $0.append(result) }
        }

        try await git(scriptedGit("printf 'Second: 100%% (1/1)\\n' >&2;"), directory, "scripted", options: opts)
        try await git(scriptedGit("printf 'First: 100%% (1/1)\\n' >&2;"), directory, "scripted", options: opts)

        // The parser remembers the step it reached.
        #expect(results.withLock { $0 }.map(\.isProgress) == [true, false])
    }
}

import GitKit
import Synchronization
import Testing

@Suite("Model helpers behavior")
struct ModelHelpersBehaviorTests {
    @Test("parses line endings after a JavaScript trim")
    func lineEndings() {
        #expect(parseLineEndingText(" CRLF\n") == .crlf)
        #expect(parseLineEndingText("CR\u{2028}") == .cr)
        // trim() removes U+FEFF but not U+0085.
        #expect(parseLineEndingText("\u{FEFF}LF") == .lf)
        #expect(parseLineEndingText("\u{85}CR") == nil)
        #expect(parseLineEndingText("cr") == nil)
    }

    @Test("a diff line's content drops exactly one code unit")
    func diffLineContent() {
        #expect(line("+line").content == "line")
        #expect(line("+\u{301}abc").content == "\u{301}abc")
        #expect(line("").content == "")
        #expect(line("-").content == "")
        #expect(line("+a").isIncludeableLine())
        #expect(!DiffLine(text: " a", type: .context, originalLineNumber: 1, oldLineNumber: 1, newLineNumber: 1).isIncludeableLine())
        #expect(line("+a").withNoTrailingNewLine(true).noTrailingNewLine)
    }

    @Test("describes worktrees")
    func worktrees() {
        #expect(getWorktreeDescription(worktree(branch: "refs/heads/main")) == "main")
        #expect(getWorktreeDescription(worktree(branch: nil)) == "0123456")
        #expect(getWorktreeDescription(worktree(branch: "")) == "0123456")
        #expect(getWorktreeDescription(worktree(branch: "refs/heads/refs/heads/y")) == "refs/heads/y")
        #expect(getWorktreeDescription(worktree(branch: "refs/tags/v1")) == "refs/tags/v1")
        #expect(getWorktreeDisplayName(worktree(path: "/a/b/")) == "b")
        #expect(getWorktreeDisplayName(worktree(path: "/a//b//")) == "b")
        #expect(getWorktreeDisplayName(worktree(path: "/")) == "")
    }

    @Test("resolves the .git directory like Node's path.join")
    func resolvedGitDir() {
        #expect(Repository(path: "/repo").resolvedGitDir == "/repo/.git")
        #expect(Repository(path: "/repo/").resolvedGitDir == "/repo/.git")
        #expect(Repository(path: "/a/../b").resolvedGitDir == "/b/.git")
        #expect(Repository(path: "").resolvedGitDir == ".git")
        #expect(Repository(path: "/repo", gitDir: "/elsewhere/.git").resolvedGitDir == "/elsewhere/.git")
        #expect(Repository(path: "/some/cool/path/").name == "path")
        #expect(Repository(path: "/repo") == Repository(path: "/repo", gitDir: "/repo/.git"))
    }

    @Test("clamps progress into a range")
    func clamp() {
        let recorder = ProgressRecorder()
        let clamped = clampProgress(0.2, 0.6) { (progress: CheckoutProgress) in
            recorder.record(progress.value)
        }
        clamped(CheckoutProgress(value: 0.5, title: "t", description: "d", target: "main"))
        #expect(recorder.values == [0.4])

        var progress = AnyProgress.fetch(FetchProgress(value: 0.25, title: "Fetching", remote: "origin"))
        progress.value = 0.75
        #expect(progress == .fetch(FetchProgress(value: 0.75, title: "Fetching", remote: "origin")))
        #expect(progress.title == "Fetching")
    }

    private func line(_ text: String) -> DiffLine {
        DiffLine(text: text, type: .add, originalLineNumber: 1, oldLineNumber: nil, newLineNumber: 2)
    }

    private func worktree(path: String = "/a", branch: String? = nil) -> WorktreeEntry {
        WorktreeEntry(
            path: path,
            head: "0123456789",
            branch: branch,
            isDetached: branch == nil,
            type: .main,
            isLocked: false,
            isPrunable: false
        )
    }
}

private final class ProgressRecorder: Sendable {
    private let storage = Mutex<[Double]>([])

    var values: [Double] {
        storage.withLock { $0 }
    }

    func record(_ value: Double) {
        storage.withLock { $0.append(value) }
    }
}

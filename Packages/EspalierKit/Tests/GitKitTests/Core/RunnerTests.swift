import EspalierSupport
import Foundation
import Synchronization
@testable import GitKit
import Testing
import TestSupport

/// Checks of the process runner itself.
@Suite("Runner")
struct RunnerTests {
    @Test("sets and removes environment variables")
    func environment() async throws {
        let dir = try createTempDirectory()
        let result = try await Dugite.exec(["var", "GIT_AUTHOR_IDENT"], dir, options: Dugite.ExecutionOptions(env: [
            "GIT_AUTHOR_NAME": "Foo Bar",
            "GIT_AUTHOR_EMAIL": "foo@bar.com",
            "GIT_AUTHOR_DATE": "Wed, 05 Oct 2016 23:33:27 +0200",
        ]))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "Foo Bar <foo@bar.com> 1475703207 +0200\n")

        let removed = try await Dugite.exec(["var", "GIT_AUTHOR_IDENT"], dir, options: Dugite.ExecutionOptions(env: [
            "GIT_AUTHOR_NAME": nil,
            "GIT_AUTHOR_EMAIL": "foo@bar.com",
            "GIT_AUTHOR_DATE": "Wed, 05 Oct 2016 23:33:27 +0200",
        ]))
        #expect(!String(decoding: removed.stdout, as: UTF8.self).contains(TestEnvironment.authorName))
    }

    @Test("terminates git when the task is cancelled", .hangGuard(minutes: 5))
    func cancellation() async throws {
        let dir = try createTempDirectory()
        // Git waits two minutes and then says it's done, unless it's
        // terminated. The alias says when it has started waiting, and the
        // task is cancelled then.
        let waiting = AsyncGate()
        let output = Mutex("")
        let task = Task {
            try await Dugite.exec(["-c", "alias.wait=!echo waiting; sleep 120; echo done", "wait"], dir, options: Dugite.ExecutionOptions(
                processCallback: { child in
                    _ = child.observeStandardOutput { chunk in
                        output.withLock { $0 += String(decoding: chunk, as: UTF8.self) }
                        waiting.open()
                    }
                }
            ))
        }
        await waiting.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // The task ended before git's wait did.
        #expect(!output.withLock { $0 }.contains("done"))
    }

    @Test("returns when git exits even if a grandchild keeps its output open", .hangGuard(minutes: 5))
    func orphanedGrandchild() async throws {
        let dir = try createTempDirectory()
        // The alias backgrounds a sleep that inherits git's stdout and would
        // outlive git and the test. It's in git's process group, which the
        // test signals afterwards, as cancelling (by the hang guard) does.
        let group = Mutex<Int32?>(nil)
        let result = try await Dugite.exec(["-c", "alias.spawn=!sleep 3600 & echo started", "spawn"], dir, options: Dugite.ExecutionOptions(
            processCallback: { child in
                group.withLock { $0 = child.processIdentifier }
            },
            killsProcessGroup: true
        ))
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("started"))
        if let group = group.withLock({ $0 }) {
            kill(-group, SIGKILL)
        }
    }

    @Test("reports a missing git as ENOENT")
    func missingGit() async throws {
        var runtime = TestEnvironment.runtime
        runtime.gitDirectory = URL(filePath: "/nonexistent/git", directoryHint: .isDirectory)
        let error = await #expect(throws: ExecError.self) {
            try await Dugite.exec(["--version"], "/", runtime: runtime)
        }
        #expect(error?.code == "ENOENT")
    }
}

/// The terminal output recorder must not slow down large binary results.
@Suite("Terminal output")
struct TerminalOutputTests {
    @Test("git() returns large binary output, and records it without decoding it")
    func largeBinaryOutput() async throws {
        let dir = try createTempDirectory()
        _ = try await Dugite.exec(["init"], dir)
        var blob = Data(count: 32 * 1024 * 1024)
        blob.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let written = try await Dugite.exec(["hash-object", "-w", "--stdin"], dir, options: Dugite.ExecutionOptions(stdin: blob))
        let sha = String(decoding: written.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try await git(["cat-file", "blob", sha], dir, "test")
        #expect(result.stdoutData == blob)

        // Decoding every chunk took over 4 seconds for this blob. With no
        // subscriber, recording all of it costs less than decoding one
        // megabyte of it, both counted in this thread's CPU time, which
        // other work on the machine doesn't add to.
        let chunkSize = 64 * 1024
        let chunks = stride(from: 0, to: blob.count, by: chunkSize).map { blob[$0..<min($0 + chunkSize, blob.count)] }
        let recording = threadCPUTime {
            let recorder = TerminalOutputRecorder(capacity: 256 * 1024)
            for chunk in chunks {
                recorder.push(chunk, from: .stdout)
            }
        }
        let megabyte = chunks.prefix(1024 * 1024 / chunkSize)
        var decodedCount = 0
        let decoding = threadCPUTime {
            for chunk in megabyte {
                decodedCount += String(decoding: chunk, as: UTF8.self).utf8.count
            }
        }
        #expect(decodedCount >= 1024 * 1024)
        #expect(recording < decoding, "recording 32 MB took \(recording), decoding 1 MB \(decoding)")
    }

    @Test("failure messages carry the terminal output when git's error isn't recognized")
    func failureOutput() async throws {
        let dir = try createTempDirectory()
        _ = try await Dugite.exec(["init"], dir)
        let error = await #expect(throws: GitError.self) {
            try await git(["rev-parse", "--verify", "no-such-ref"], dir, "test")
        }
        #expect(error?.result.gitError == nil)
        #expect(error?.isRawMessage == true)
        #expect(error?.message == "fatal: Needed a single revision\n")
    }

    @Test("subscribers receive replayed and live output in order")
    func subscribers() async throws {
        let dir = try createTempDirectory()
        _ = try await Dugite.exec(["init"], dir)
        // One subscriber from the start, and one that subscribes once output
        // has arrived, so what came before is replayed to it.
        let early = Mutex("")
        let late = Mutex("")
        let listener = Mutex<TerminalOutputListener?>(nil)
        let lateSubscribed = Mutex(false)
        try await git(["-c", "alias.say=!printf 'h\u{E9}llo ' && printf 'w\u{F6}rld' && printf '\u{FC}nd' >&2", "say"], dir, "test", options: GitExecutionOptions(
            processCallback: { process in
                _ = process.observeStandardOutput { _ in
                    let subscribe = lateSubscribed.withLock { subscribed in
                        defer { subscribed = true }
                        return subscribed ? nil : listener.withLock { $0 }
                    }
                    _ = subscribe? { chunk in late.withLock { $0 += chunk } }
                }
            },
            onTerminalOutputAvailable: { subscribe in
                listener.withLock { $0 = subscribe }
                _ = subscribe { chunk in early.withLock { $0 += chunk } }
            }
        ))

        // git() returns once subscribers have received all of the output.
        // Standard output's two writes stay in order; standard error's may
        // come before, between, or after them.
        let text = early.withLock { $0 }
        #expect(text.replacing("\u{FC}nd", with: "") == "h\u{E9}llo w\u{F6}rld")
        #expect(text.contains("\u{FC}nd"))
        #expect(late.withLock { $0 } == text)
    }
}

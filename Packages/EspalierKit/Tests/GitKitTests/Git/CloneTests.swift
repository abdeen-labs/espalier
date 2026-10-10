// Ported from desktop/app/test/unit/git/clone-test.ts
//
// These set variables for their own task with `withGitEnvironment`. The
// hermetic test environment already has no GIT_ALLOW_PROTOCOL or
// GIT_CONFIG_PARAMETERS.

import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

private func createEmptyBareRepository() async throws -> String {
    let bareParentPath = try createTempDirectory()
    let barePath = POSIXPath.join(bareParentPath, "remote.git")
    try await git(["init", "--bare", barePath], bareParentPath, "initBareRepository")
    return barePath
}

/// Node's `pathToFileURL(path).href`.
private func fileURL(_ path: String) -> String {
    URL(filePath: path, directoryHint: .notDirectory).absoluteString
}

/// Expects `operation` to fail with a git error whose standard error
/// contains `text`.
private func expectGitError(containing text: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected a git error containing \(text)")
    } catch let error as GitError {
        let stderr = error.result.stderr
        #expect(stderr.contains(text), "\(stderr)")
    } catch {
        Issue.record("Expected a git error, got \(error)")
    }
}

/// Expects `operation` to refuse a sensitive destination.
private func expectSensitiveLocationError(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected sensitive location error")
    } catch {
        #expect(
            "\(error)".contains("protected system location"),
            "Expected sensitive location error, got: \(error)"
        )
    }
}

/// The test runtime's home directory: the hermetic environment sets `HOME`
/// to an empty string.
private func testHomeDirectory() -> String {
    TestEnvironment.runtime.processEnvironment["HOME"] ?? NSHomeDirectory()
}

@Suite("git/clone")
struct CloneTests {
    @Suite("transport policy")
    struct TransportPolicy {
        @Test("rejects protocol URLs before creating the destination", arguments: ["ext"])
        func rejectsUnsupportedURLs(_ proto: String) async throws {
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")

            await #expect(throws: CloneError(message: "The \"\(proto)\" transport is not supported for cloning in Espalier.")) {
                try await clone("\(proto)::", destination, CloneOptions())
            }
            #expect(!FileManager.default.fileExists(atPath: destination))
        }

        @Test(
            "rejects rewrites to protocol with GIT_ALLOW_PROTOCOL",
            arguments: ["ext"], [nil, "ext:ext.exe:file", "ext:ext.exe"] as [String?]
        )
        func rejectsRewrites(_ proto: String, _ allowProtocol: String?) async throws {
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")
            let env: [String: String?] = [
                "GIT_CONFIG_PARAMETERS": "'protocol.\(proto).allow=always' 'url.\(proto)::.insteadOf=desktop-clone-test:'",
                "GIT_ALLOW_PROTOCOL": allowProtocol,
            ]

            try await withGitEnvironment(env) {
                await expectGitError(containing: "transport '\(proto)' not allowed") {
                    try await clone("desktop-clone-test:", destination, CloneOptions())
                }
            }
        }

        @Test("leaves URL transport selection to Git", arguments: [
            ("https://[::1]/owner/repo.git", "https"),
            ("git@example.com:owner/repo.git", "ssh"),
            ("desktop-test-helper::", "desktop-test-helper"),
        ])
        func leavesTransportToGit(_ url: String, _ proto: String) async throws {
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")
            // Stop at Git's transport check without connecting or starting a helper.
            try await withGitEnvironment(["GIT_ALLOW_PROTOCOL": ""]) {
                await expectGitError(containing: "transport '\(proto)' not allowed") {
                    try await clone(url, destination, CloneOptions())
                }
            }
        }

        @Test("preserves file clones with GIT_ALLOW_PROTOCOL", arguments: [nil, "ext:file:ext.exe"] as [String?])
        func preservesFileClones(_ allowProtocol: String?) async throws {
            let source = try await createEmptyBareRepository()
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")

            try await withGitEnvironment(["GIT_ALLOW_PROTOCOL": allowProtocol]) {
                try await clone(fileURL(source), destination, CloneOptions())

                #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, ".git")))
                #expect(GitRuntime.current.processEnvironment["GIT_ALLOW_PROTOCOL"] == allowProtocol)
            }
        }

        @Test("preserves file restrictions with GIT_ALLOW_PROTOCOL", arguments: ["", "ext:ext.exe"])
        func preservesFileRestrictions(_ allowProtocol: String) async throws {
            let source = try await createEmptyBareRepository()
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")

            try await withGitEnvironment(["GIT_ALLOW_PROTOCOL": allowProtocol]) {
                await expectGitError(containing: "transport 'file' not allowed") {
                    try await clone(fileURL(source), destination, CloneOptions())
                }
                #expect(GitRuntime.current.processEnvironment["GIT_ALLOW_PROTOCOL"] == allowProtocol)
            }
        }

        @Test("preserves recursive protocol policy with GIT_ALLOW_PROTOCOL", arguments: [
            ("file", nil),
            ("file", "file:ext:ext.exe"),
            ("ext", "file:ext:ext.exe"),
        ] as [(String, String?)])
        func preservesRecursivePolicy(_ proto: String, _ allowProtocol: String?) async throws {
            let submodule = try setupEmptyRepository()
            try await makeCommit(submodule, Tree(entries: [TreeEntry(path: "README.md", contents: "submodule")]))
            let submoduleURL = fileURL(submodule.path)
            let source = try setupEmptyRepository()
            try await git(
                [
                    "-c",
                    "protocol.file.allow=always",
                    "submodule",
                    "add",
                    "--",
                    submoduleURL,
                    "module",
                ],
                source.path,
                "addSubmodule"
            )
            try await makeCommit(source, Tree(entries: []))

            var env: [String: String?] = ["GIT_ALLOW_PROTOCOL": allowProtocol]
            if proto != "file" {
                env["GIT_CONFIG_PARAMETERS"] = "'protocol.\(proto).allow=always' 'url.\(proto)::.insteadOf=\(submoduleURL)'"
            }
            let destination = POSIXPath.join(try createTempDirectory(), "cloned")

            try await withGitEnvironment(env) {
                if proto == "file" && allowProtocol != nil {
                    try await clone(source.path, destination, CloneOptions())
                    #expect(FileManager.default.fileExists(atPath: POSIXPath.join(destination, "module", "README.md")))
                } else {
                    await expectGitError(containing: "transport '\(proto)' not allowed") {
                        try await clone(source.path, destination, CloneOptions())
                    }
                }
            }
        }
    }

    @Test("clones a local repository")
    func clonesLocalRepository() async throws {
        // Create a source repo with a commit
        let source = try setupEmptyRepository()
        try await makeCommit(source, Tree(
            entries: [TreeEntry(path: "README.md", contents: "hello")],
            commitMessage: "initial commit"
        ))

        let destPath = try createTempDirectory()
        let clonePath = POSIXPath.join(destPath, "cloned")

        try await clone(source.path, clonePath, CloneOptions())

        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(clonePath, ".git")))
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(clonePath, "README.md")))
    }

    @Test("clones with a specific branch")
    func clonesBranch() async throws {
        let source = try setupEmptyRepository()
        try await makeCommit(source, Tree(
            entries: [TreeEntry(path: "README.md", contents: "hello")],
            commitMessage: "initial commit"
        ))

        // Create a feature branch on the source
        _ = try await Dugite.exec(["branch", "feature"], source.path)
        _ = try await Dugite.exec(["checkout", "feature"], source.path)
        try await makeCommit(source, Tree(
            entries: [TreeEntry(path: "feature.txt", contents: "feature")],
            commitMessage: "feature commit"
        ))
        _ = try await Dugite.exec(["checkout", "master"], source.path)

        let destPath = try createTempDirectory()
        let clonePath = POSIXPath.join(destPath, "cloned")

        try await clone(source.path, clonePath, CloneOptions(branch: "feature"))

        // Verify the feature branch was checked out
        let result = try await Dugite.exec(["rev-parse", "--abbrev-ref", "HEAD"], clonePath)
        #expect(JSCompat.trim(String(decoding: result.stdout, as: UTF8.self)) == "feature")
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(clonePath, "feature.txt")))
    }

    @Test("reports progress when callback is provided")
    func reportsProgress() async throws {
        let source = try setupEmptyRepository()
        try await makeCommit(source, Tree(
            entries: [TreeEntry(path: "README.md", contents: "hello")],
            commitMessage: "initial commit"
        ))

        let destPath = try createTempDirectory()
        let clonePath = POSIXPath.join(destPath, "cloned")

        let progressEvents = Mutex<[CloneProgress]>([])
        try await clone(source.path, clonePath, CloneOptions()) { progress in
            progressEvents.withLock { $0.append(progress) }
        }

        let events = progressEvents.withLock { $0 }
        #expect(!events.isEmpty, "Expected at least one progress event")
        #expect(events.first == CloneProgress(value: 0, title: "Cloning into \(clonePath)"))
    }

    @Test("clones with a custom default branch name")
    func customDefaultBranch() async throws {
        // init.defaultBranch only takes effect when the remote's unborn HEAD
        // branch name is not advertised (protocol v0/v1). Force protocol v0
        // so we can verify the option actually drives the result, rather than
        // having the remote's initial-branch setting do the work.
        try await withGitEnvironment(["GIT_CONFIG_PARAMETERS": "'protocol.version=0'"]) {
            // Bare repo defaults to 'master' — clone must use defaultBranch to get 'trunk'
            let source = try await createEmptyBareRepository()

            let destPath = try createTempDirectory()
            let clonePath = POSIXPath.join(destPath, "cloned")

            try await clone(source, clonePath, CloneOptions(defaultBranch: "trunk"))

            #expect(FileManager.default.fileExists(atPath: POSIXPath.join(clonePath, ".git")))

            let result = try await Dugite.exec(["symbolic-ref", "HEAD"], clonePath)
            #expect(JSCompat.trim(String(decoding: result.stdout, as: UTF8.self)) == "refs/heads/trunk")
        }
    }

    @Test("rejects cloning into a sensitive location in HOME", arguments: [
        NamedCase("rejects cloning into ~/.ssh", [".ssh", "malicious-clone"]),
        NamedCase("rejects cloning into home directory root", []),
    ])
    func rejectsSensitiveLocation(_ testCase: NamedCase<[String]>) async {
        let home = testHomeDirectory()
        let path = testCase.value.isEmpty ? home : POSIXPath.join([home] + testCase.value)

        await expectSensitiveLocationError {
            try await clone("https://example.com/repo.git", path, CloneOptions())
        }
    }

    // MARK: - Espalier

    @Test("rejects sensitive locations in the account's home directory whatever HOME says")
    func rejectsAccountHome() async {
        let home = NSHomeDirectory()
        for path in [
            home,
            POSIXPath.join(home, ".ssh"),
            POSIXPath.join(home, ".SSH", "clone"),
            POSIXPath.join(home, ".gnupg", "clone"),
            POSIXPath.join(home, ".gitconfig"),
            POSIXPath.join(home, "Projects", "..", ".config", "clone"),
        ] {
            await expectSensitiveLocationError {
                try await clone("https://example.com/repo.git", path, CloneOptions())
            }
        }
    }

    @Test("allows other locations")
    func allowsOtherLocations() {
        let home = NSHomeDirectory()
        let environment = ["HOME": home]
        #expect(!isClonePathSensitive(POSIXPath.join(home, "Projects", "repo"), environment: environment))
        #expect(!isClonePathSensitive(POSIXPath.join(home, ".sshkeys"), environment: environment))
        #expect(!isClonePathSensitive("/tmp/repo", environment: environment))
        #expect(isClonePathSensitive(POSIXPath.join(home, ".ssh"), environment: environment))
    }

    @Test("cancelling stops git and the processes it started, and git removes what it cloned", .hangGuard(minutes: 5))
    func cancellingStopsProcessGroup() async throws {
        let source = try setupEmptyRepository()
        try await makeCommit(source, Tree(entries: [TreeEntry(path: "README.md", contents: "hello")]))
        let gate = try SSHGate()
        let destination = POSIXPath.join(try createTempDirectory(), "cloned")

        try await withGitEnvironment(gate.environment) {
            let progress = Mutex<[CloneProgress]>([])
            let cloning = Task {
                try await clone(gate.url(source.path), destination, CloneOptions()) { event in
                    progress.withLock { $0.append(event) }
                }
            }
            let held = try await gate.waitUntilRunning(while: cloning)
            defer { Darwin.close(held) }
            cloning.cancel()

            await #expect(throws: CancellationError.self) {
                try await cloning.value
            }
            // The ssh script, a child of git, ends too: the pipe it held
            // reaches its end, and nothing waits at the gate.
            #expect(await gate.waitUntilGone(held))
            #expect(!gate.release())
            #expect(!FileManager.default.fileExists(atPath: destination))
            #expect(progress.withLock { $0.first } == CloneProgress(value: 0, title: "Cloning into \(destination)"))
        }
    }
}

/// Holds a clone inside git until released, without the network: git's ssh
/// is a script (`GIT_SSH_COMMAND`) that opens a named pipe (`gate`) for
/// reading and writing, which doesn't wait, then opens another (`held`) for
/// writing, which waits until the test opens it for reading, then waits to
/// read a line from `gate`, and then runs the command git asked the server
/// for (`git-upload-pack '<path>'`) here. No process runs while it waits.
/// Once the test holds `held`, the script has `gate` open, so releasing it
/// never races the script. (Local clones can't be held this way: clone
/// ignores `-c remote.origin.uploadpack`, and the file transport keeps
/// `GIT_CONFIG_PARAMETERS` from upload-pack.)
private struct SSHGate: Sendable {
    let held: String
    let gate: String
    let script: String

    init() throws {
        let directory = try createTempDirectory(prefix: "espalier-gate-")
        held = POSIXPath.join(directory, "held")
        gate = POSIXPath.join(directory, "gate")
        script = POSIXPath.join(directory, "ssh")
        guard mkfifo(held, 0o600) == 0, mkfifo(gate, 0o600) == 0 else {
            throw TestSupportError("Could not make the named pipes: \(String(cString: strerror(errno)))")
        }
        try Data("""
            #!/bin/sh
            exec 4<>'\(gate)'
            exec 3>'\(held)'
            read line <&4
            exec 3>&- 4<&-
            exec sh -c "$2"
            """.utf8).write(to: URL(filePath: script))
        guard chmod(script, 0o755) == 0 else {
            throw TestSupportError("Could not make the script executable")
        }
    }

    /// Makes git run the script as ssh, with only the host and the command
    /// as its arguments.
    var environment: [String: String?] {
        ["GIT_SSH_COMMAND": script, "GIT_SSH_VARIANT": "simple"]
    }

    /// The ssh URL of the repository at `path`.
    func url(_ path: String) -> String {
        "ssh://localhost\(path)"
    }

    private enum Wait { case waiting, held, cloneEnded }

    /// Waits until the script runs; returns the read end of `held`. A clone
    /// that ends without running the script fails the wait rather than
    /// leaving it waiting.
    func waitUntilRunning<T: Sendable>(while cloning: Task<T, any Error>) async throws -> Int32 {
        let held = held
        let state = Mutex(Wait.waiting)
        // Whichever comes first, the script or the end of the clone, decides
        // the wait. A clone that ended first opens `held` for writing, which
        // ends the open for reading below: it waits for that reader, so it
        // works whether or not the reader has started waiting yet.
        let watchdog = Task.detached {
            _ = await cloning.result
            let ended = state.withLock { state in
                guard state == .waiting else { return false }
                state = .cloneEnded
                return true
            }
            if ended {
                await onThread {
                    let descriptor = Darwin.open(held, O_WRONLY)
                    if descriptor >= 0 {
                        Darwin.close(descriptor)
                    }
                }
            }
        }
        let descriptor = await onThread { Darwin.open(held, O_RDONLY) }
        guard descriptor >= 0 else {
            throw TestSupportError("Could not open the named pipe: \(String(cString: strerror(errno)))")
        }
        let isHeld = state.withLock { state in
            guard state == .waiting else { return false }
            state = .held
            return true
        }
        guard isHeld else {
            // The watchdog's open for writing needs this reader: close it
            // only once that open is done.
            await watchdog.value
            Darwin.close(descriptor)
            throw TestSupportError("The clone ended without running the gate's script")
        }
        return descriptor
    }

    /// Lets the waiting script go on; returns whether it was there: the
    /// script has `gate` open from its start until it goes on or is gone.
    @discardableResult
    func release() -> Bool {
        let descriptor = Darwin.open(gate, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            return false
        }
        _ = Darwin.write(descriptor, "\n", 1)
        Darwin.close(descriptor)
        return true
    }

    /// Waits until every process holding `held` (the read end) is gone: a
    /// read finds its end. Cancelling signals git's whole process group;
    /// a helper still exiting is waited for, with no deadline. Returns
    /// false when the task is cancelled first (by a test's hang guard).
    ///
    /// The read blocks on a thread of its own (neither `poll` nor a kqueue
    /// reports a named pipe's end on macOS), on a duplicate of `descriptor`:
    /// closing a descriptor that a thread is reading waits for the read, so
    /// the caller's close after a cancelled wait doesn't.
    func waitUntilGone(_ descriptor: Int32) async -> Bool {
        let reading = dup(descriptor)
        guard reading >= 0 else {
            return false
        }
        let gone = AsyncEvent<Bool>()
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(reading, &byte, 1)
                if count == 0 || (count < 0 && errno != EINTR) {
                    Darwin.close(reading)
                    return gone.resolve(count == 0)
                }
            }
        }
        return (try? await gone.wait()) ?? false
    }
}

/// Runs a blocking call on a thread of its own.
private func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: body())
        }
    }
}

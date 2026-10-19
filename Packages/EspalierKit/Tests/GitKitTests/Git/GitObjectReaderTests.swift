// These tests prove that `getBlobContents` and `getPartialBlobContents`,
// which answer from the long-lived `git cat-file --batch` when they can,
// return exactly what `git show <rev>:<path>` returns, and exercise the
// reader itself.

import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

// MARK: - Helpers

/// Deterministic bytes that don't compress, so blobs stay as big as asked.
private func pseudoRandomBytes(count: Int, seed: UInt64) -> Data {
    var state = seed | 1
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for index in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
    }
    return data
}

private let largeBlobSize = 2 * 1024 * 1024 + 3

/// A repository whose HEAD holds every kind of blob the equivalence tests
/// read, with textconv, filters, end-of-line, and encoding settings that
/// `git show` must not apply.
private func makeBlobRepository() async throws -> Repository {
    let repo = try setupEmptyRepository()
    var entries = [
        TreeEntry(path: "text.txt", contents: "hello\nworld\n"),
        TreeEntry(path: "crlf.txt", contents: "line one\r\nline two\r\n"),
        TreeEntry(path: "unicode.txt", contents: "caf\u{E9} \u{1F600} \u{2028} end\n"),
        TreeEntry(path: "empty.txt", contents: ""),
        TreeEntry(path: "binary.dat", contents: Data((0...255).map { UInt8($0) } + [0, 0, 1])),
        TreeEntry(path: "invalid-utf8.txt", contents: Data([0x61, 0xC3, 0x28, 0xFF, 0x0A])),
        TreeEntry(path: "large.bin", contents: pseudoRandomBytes(count: largeBlobSize, seed: 42)),
        TreeEntry(path: "medium.bin", contents: pseudoRandomBytes(count: 100 * 1024, seed: 7)),
        TreeEntry(path: "upper.conv", contents: "lower case\n"),
        TreeEntry(path: "smudge.flt", contents: "smudge me\n"),
        TreeEntry(path: "encoded.txt", contents: "caf\u{E9}\n"),
        TreeEntry(path: "with space.txt", contents: "spaces\n"),
        TreeEntry(path: "colon:name.txt", contents: "colon\n"),
    ]
    try FileManager.default.createDirectory(atPath: POSIXPath.join(repo.path, "dir"), withIntermediateDirectories: false)
    entries.append(TreeEntry(path: "dir/nested.txt", contents: "nested\n"))
    try await makeCommit(repo, Tree(entries: entries, commitMessage: "blobs"))

    // Configured after committing, so that `git add` didn't apply them.
    try await setupLocalConfig(repo, [
        ("diff.upper.textconv", "tr a-z A-Z <"),
        ("filter.rev.smudge", "rev"),
        ("filter.rev.clean", "cat"),
        ("core.autocrlf", "true"),
    ])
    try await makeCommit(repo, Tree(entries: [
        TreeEntry(
            path: ".gitattributes",
            contents: "*.conv diff=upper\ncrlf.txt text eol=crlf\n*.flt filter=rev\nencoded.txt working-tree-encoding=UTF-16\n"
        ),
    ], commitMessage: "attributes"))
    return repo
}

private let blobPaths = [
    "text.txt", "crlf.txt", "unicode.txt", "empty.txt", "binary.dat", "invalid-utf8.txt", "large.bin",
    "medium.bin", "upper.conv", "smudge.flt", "encoded.txt", "with space.txt", "colon:name.txt",
    "dir/nested.txt", ".gitattributes",
]

/// Writes `files` and commits them with one `git add`, which is much faster
/// than `makeCommit` for many files.
private func commitFiles(_ repo: Repository, _ files: [(path: String, contents: Data)]) async throws {
    for file in files {
        try file.contents.write(to: URL(filePath: POSIXPath.join(repo.path, file.path)))
    }
    _ = try await Dugite.exec(["add", "--all"], repo.path)
    _ = try await Dugite.exec(["commit", "-m", "files"], repo.path)
}

/// The reference: `git show <name>`, exit codes 0 and 1.
private func desktopBlobContents(_ repo: Repository, _ name: String) async -> Result<Data, GitError> {
    do {
        let result = try await git(["show", name], repo.path, "getBlobContents", options: GitExecutionOptions(
            successExitCodes: [0, 1]
        ))
        return .success(result.stdoutData)
    } catch let error as GitError {
        return .failure(error)
    } catch {
        Issue.record("Unexpected error \(error)")
        return .success(Data())
    }
}

/// The reference for getPartialBlobContents.
private func desktopPartialBlobContents(_ repo: Repository, _ name: String, _ length: Int) async throws -> Data? {
    do {
        let result = try await git(["show", name], repo.path, "getPartialBlobContentsCatchPathNotInRef", options: GitExecutionOptions(
            maxBuffer: length,
            expectedErrors: [.pathExistsButNotInRef]
        ))
        return result.gitError == .pathExistsButNotInRef ? nil : result.stdoutData
    } catch let error as ExecError where error.isMaxBufferExceeded {
        return error.stdout
    }
}

/// A partial read's outcome: its bytes (or nil), or how git failed.
private enum PartialOutcome: Equatable {
    case contents(Data?)
    case failure(exitCode: Int, gitError: DugiteError?, stderr: String)
}

private func partialOutcome(_ read: () async throws -> Data?) async -> PartialOutcome {
    do {
        return .contents(try await read())
    } catch let error as GitError {
        return .failure(exitCode: error.result.exitCode, gitError: error.result.gitError, stderr: error.result.stderr)
    } catch {
        Issue.record("Unexpected error \(error)")
        return .contents(nil)
    }
}

/// GitKit's getBlobContents, as a result.
private func blobContents(_ repo: Repository, _ commitish: String, _ path: String) async -> Result<Data, GitError> {
    do {
        return .success(try await getBlobContents(repo, commitish, path))
    } catch let error as GitError {
        return .failure(error)
    } catch {
        Issue.record("Unexpected error \(error)")
        return .success(Data())
    }
}

/// Expects two outcomes to be the same bytes, or the same git failure.
private func expectSame(
    _ actual: Result<Data, GitError>,
    _ expected: Result<Data, GitError>,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch (actual, expected) {
    case (.success(let actualData), .success(let expectedData)):
        #expect(actualData == expectedData, comment, sourceLocation: sourceLocation)
    case (.failure(let actualError), .failure(let expectedError)):
        #expect(actualError.args == expectedError.args, comment, sourceLocation: sourceLocation)
        #expect(actualError.message == expectedError.message, comment, sourceLocation: sourceLocation)
        #expect(actualError.result.exitCode == expectedError.result.exitCode, comment, sourceLocation: sourceLocation)
        #expect(actualError.result.gitError == expectedError.result.gitError, comment, sourceLocation: sourceLocation)
        #expect(actualError.result.stderr == expectedError.result.stderr, comment, sourceLocation: sourceLocation)
        #expect(actualError.result.stdoutData == expectedError.result.stdoutData, comment, sourceLocation: sourceLocation)
    default:
        Issue.record("Expected \(expected), got \(actual). \(comment.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
    }
}

/// Runs `git show` once for `reader`, as getBlobContents does the first
/// time, so that later reads may come from cat-file.
private func validate(_ reader: GitObjectReader, _ repo: Repository, _ name: String = "HEAD:text.txt") async throws {
    if case .runShow(let state?) = try await reader.attemptShow(name, limit: nil) {
        let result = try await git(["show", name], repo.path, "getBlobContents")
        try #require(result.exitCode == 0)
        await reader.showSucceeded(in: state)
    }
}

/// The blob `attemptShow` served, or nil if it sent the caller to git.
private func served(_ attempt: GitObjectReader.ShowAttempt) -> Data? {
    if case .blob(let data) = attempt {
        return data
    }
    return nil
}

private func revParse(_ repo: Repository, _ revision: String) async throws -> String {
    JSCompat.trim(try await git(["rev-parse", revision], repo.path, "test").stdout)
}

/// The reader's events from now on. Subscribe after any reads that set the
/// test up, so that their events don't count.
private func readerEvents(of reader: GitObjectReader) async -> AsyncStream<GitObjectReader.Event>.Iterator {
    let (stream, continuation) = AsyncStream.makeStream(of: GitObjectReader.Event.self)
    await reader.observeEvents { continuation.yield($0) }
    return stream.makeAsyncIterator()
}

/// Waits until the reader reports `event`, skipping the others.
private func wait(for event: GitObjectReader.Event, in events: inout AsyncStream<GitObjectReader.Event>.Iterator) async {
    while let next = await events.next(), next != event {}
}

/// The first process ID it's given.
private final class FirstProcess: Sendable {
    private let first = Mutex<Int32?>(nil)

    var processIdentifier: Int32? {
        first.withLock { $0 }
    }

    /// Whether `pid` is the first process ID given.
    func claim(_ pid: Int32) -> Bool {
        first.withLock { claimed in
            guard claimed == nil else {
                return false
            }
            claimed = pid
            return true
        }
    }
}

private func processIsGone(_ pid: Int32) async -> Bool {
    for _ in 0..<200 {
        if kill(pid, 0) != 0, errno == ESRCH {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

// MARK: - Tests

@Suite("GitObjectReader")
struct GitObjectReaderTests {
    @Suite("equivalence with git show")
    struct Equivalence {
        @Test("getBlobContents returns exactly what git show prints, for every kind of blob and revision form")
        func blobContentsMatchGitShow() async throws {
            let repo = try await makeBlobRepository()
            let head = try await revParse(repo, "HEAD")
            let reader = GitObjectReader.shared(for: repo)

            for revision in ["HEAD", head, "\(head)^", "HEAD~1", "HEAD^1"] {
                for path in blobPaths {
                    let name = "\(revision):\(path)"
                    let expected = await desktopBlobContents(repo, name)
                    let actual = await blobContents(repo, revision, path)
                    expectSame(actual, expected, "\(name)")
                }
            }

            // The reader answered (rather than every read falling back to git).
            let served = served(try await reader.attemptShow("HEAD:large.bin", limit: nil))
            #expect(served == pseudoRandomBytes(count: largeBlobSize, seed: 42))
            #expect(await reader.processesStarted == 1)
        }

        @Test("missing paths, paths not in the ref, trees, and submodules fail or print exactly as git show does")
        func failuresMatchGitShow() async throws {
            let repo = try await makeBlobRepository()
            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo)

            // In the working directory but not in HEAD: PathExistsButNotInRef.
            try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "untracked.txt")))

            let submodule = try await setupTwoCommitRepo()
            _ = try await Dugite.exec(
                ["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "sub"],
                repo.path
            )
            _ = try await Dugite.exec(["commit", "-m", "submodule"], repo.path)

            for (revision, path) in [
                ("HEAD", "does-not-exist"),
                ("HEAD", "untracked.txt"),
                ("HEAD", "dir"),
                ("HEAD", "dir/"),
                ("HEAD", "sub"),
                ("HEAD", ""),
                ("no-such-branch", "text.txt"),
                ("HEAD~99", "text.txt"),
                ("0000000000000000000000000000000000000000", "text.txt"),
            ] {
                let name = "\(revision):\(path)"
                expectSame(await blobContents(repo, revision, path), await desktopBlobContents(repo, name), "\(name)")
            }

            let pathNotInRef = await blobContents(repo, "HEAD", "untracked.txt")
            guard case .failure(let error) = pathNotInRef else {
                Issue.record("Expected PathExistsButNotInRef, got \(pathNotInRef)")
                return
            }
            #expect(error.result.gitError == .pathExistsButNotInRef)
            #expect(try await getPartialBlobContents(repo, "HEAD", "untracked.txt", 256 * 1024) == nil)

            #expect(served(try await reader.attemptShow("HEAD:does-not-exist", limit: nil)) == nil)
            #expect(served(try await reader.attemptShow("HEAD:dir", limit: nil)) == nil)
            #expect(served(try await reader.attemptShow("HEAD:sub", limit: nil)) == nil)
        }

        @Test("names git show reads differently go to git show")
        func syntaxAndAmbiguityGoToGitShow() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [
                TreeEntry(path: "a", contents: "a\n"),
                TreeEntry(path: "a..y", contents: "range-like\n"),
                TreeEntry(path: "f^-z", contents: "parent-like\n"),
                TreeEntry(path: "c^@", contents: "parents\n"),
                TreeEntry(path: "ambiguous", contents: "blob\n"),
            ]))
            _ = try await Dugite.exec(["branch", "y"], repo.path)
            // A file literally named like the object name makes git show's
            // argument ambiguous.
            try Data("file\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "HEAD:ambiguous")))

            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo, "HEAD:a")

            for path in ["a..y", "f^-z", "c^@", "ambiguous"] {
                let name = "HEAD:\(path)"
                #expect(served(try await reader.attemptShow(name, limit: nil)) == nil, "\(name)")
                expectSame(await blobContents(repo, "HEAD", path), await desktopBlobContents(repo, name), "\(name)")
            }

            // git show treats the first as a range and refuses the last two.
            if case .success(let rangeOutput) = await blobContents(repo, "HEAD", "a..y") {
                #expect(rangeOutput != Data("range-like\n".utf8))
            }
            if case .success = await blobContents(repo, "HEAD", "f^-z") {
                Issue.record("Expected git show to reject HEAD:f^-z")
            }
            if case .success = await blobContents(repo, "HEAD", "ambiguous") {
                Issue.record("Expected git show to reject the ambiguous HEAD:ambiguous")
            }
        }

        @Test("a configuration git show rejects makes reads fail as they do in desktop")
        func configurationGitShowRejects() async throws {
            let repo = try await makeBlobRepository()
            let reader = GitObjectReader.shared(for: repo)

            expectSame(await blobContents(repo, "HEAD", "text.txt"), await desktopBlobContents(repo, "HEAD:text.txt"))
            #expect(served(try await reader.attemptShow("HEAD:text.txt", limit: nil)) != nil)

            // cat-file never reads log configuration; git show refuses a bad value.
            try await setupLocalConfig(repo, [("log.date", "bogus")])

            #expect(served(try await reader.attemptShow("HEAD:text.txt", limit: nil)) == nil)
            let afterBadConfig = await blobContents(repo, "HEAD", "text.txt")
            expectSame(afterBadConfig, await desktopBlobContents(repo, "HEAD:text.txt"))
            guard case .failure = afterBadConfig else {
                Issue.record("Expected git show to fail with log.date=bogus")
                return
            }

            // Fixed again: served by the reader after one more git show.
            _ = try await Dugite.exec(["config", "--unset", "log.date"], repo.path)
            expectSame(await blobContents(repo, "HEAD", "text.txt"), await desktopBlobContents(repo, "HEAD:text.txt"))
            #expect(served(try await reader.attemptShow("HEAD:text.txt", limit: nil)) == Data("hello\nworld\n".utf8))
        }

        @Test("getPartialBlobContents keeps desktop's truncation")
        func partialContentsMatchDesktop() async throws {
            let repo = try await makeBlobRepository()
            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo)

            for (path, length) in [
                ("large.bin", 256 * 1024),
                ("large.bin", 64 * 1024),
                ("large.bin", largeBlobSize),
                ("large.bin", largeBlobSize + 1),
                ("medium.bin", 64 * 1024),
                ("medium.bin", 100 * 1024),
                ("text.txt", 256 * 1024),
                ("empty.txt", 256 * 1024),
                ("large.bin", 100),
                ("text.txt", 5),
                ("text.txt", 0),
                ("does-not-exist", 256 * 1024),
            ] {
                let expected = await partialOutcome { try await desktopPartialBlobContents(repo, "HEAD:\(path)", length) }
                let actual = await partialOutcome { try await getPartialBlobContents(repo, "HEAD", path, length) }
                #expect(actual == expected, "\(path) \(length)")
            }

            #expect(
                served(try await reader.attemptShow("HEAD:large.bin", limit: 256 * 1024))
                    == pseudoRandomBytes(count: largeBlobSize, seed: 42).prefix(256 * 1024)
            )
        }

        @Test("a partial clone's missing blob is fetched by git show, as in desktop")
        func partialClone() async throws {
            let source = try setupEmptyRepository()
            try await makeCommit(source, Tree(entries: [TreeEntry(path: "lazy.txt", contents: "fetched on demand\n")]))
            _ = try await Dugite.exec(["config", "uploadpack.allowFilter", "true"], source.path)
            _ = try await Dugite.exec(["config", "uploadpack.allowAnySHA1InWant", "true"], source.path)

            let clonePath = try createTempDirectory()
            let clone = try await Dugite.exec(
                ["clone", "--no-checkout", "--filter=blob:none", "file://\(source.path)", clonePath],
                clonePath
            )
            try #require(clone.exitCode == 0, "\(String(decoding: clone.stderr, as: UTF8.self))")
            let repo = Repository(path: clonePath)
            let blob = try await revParse(repo, "HEAD:lazy.txt")
            let present = try await Dugite.exec(["cat-file", "-e", blob], clonePath, options: Dugite.ExecutionOptions(
                env: ["GIT_NO_LAZY_FETCH": "1"]
            ))
            try #require(present.exitCode != 0, "The blob should start out missing")

            // Validate with the root tree, which the clone has, so nothing is fetched.
            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo, "HEAD:")
            // The reader never fetches...
            #expect(served(try await reader.attemptShow("HEAD:lazy.txt", limit: nil)) == nil)
            // ...so git show does.
            #expect(try await getBlobContents(repo, "HEAD", "lazy.txt") == Data("fetched on demand\n".utf8))
            // Now local, the reader serves it.
            #expect(served(try await reader.attemptShow("HEAD:lazy.txt", limit: nil)) == Data("fetched on demand\n".utf8))
        }

        @Test("works in SHA-256 repositories")
        func sha256Repository() async throws {
            let path = try createTempDirectory()
            _ = try await Dugite.exec(["init", "--object-format=sha256", "-b", "main"], path)
            let repo = Repository(path: path)
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "sha-256\n")]))
            let head = try await revParse(repo, "HEAD")
            #expect(head.count == 64)

            let reader = GitObjectReader.shared(for: repo)
            for revision in ["HEAD", head, String(head.prefix(40))] {
                expectSame(await blobContents(repo, revision, "file.txt"), await desktopBlobContents(repo, "\(revision):file.txt"))
            }
            #expect(served(try await reader.attemptShow("\(head):file.txt", limit: nil)) == Data("sha-256\n".utf8))
            // Forty characters are an abbreviation here: git show resolves it.
            #expect(served(try await reader.attemptShow("\(head.prefix(40)):file.txt", limit: nil)) == nil)
        }
    }

    @Suite("freshness")
    struct Freshness {
        @Test("a replace ref added while the process runs is honored")
        func replaceRefs() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "f", contents: "one\n")]))
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "f", contents: "two\n")]))
            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo, "HEAD:f")
            #expect(served(try await reader.attemptShow("HEAD:f", limit: nil)) == Data("two\n".utf8))

            let one = try await revParse(repo, "HEAD^:f")
            let two = try await revParse(repo, "HEAD:f")
            _ = try await Dugite.exec(["replace", two, one], repo.path)

            expectSame(await blobContents(repo, "HEAD", "f"), await desktopBlobContents(repo, "HEAD:f"))
            #expect(try await getBlobContents(repo, "HEAD", "f") == Data("one\n".utf8))
        }

        @Test("index and abbreviated names are never read from the long-lived process")
        func indexAndAbbreviatedNames() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "f", contents: "committed\n")]))
            let reader = GitObjectReader.shared(for: repo)
            try await validate(reader, repo, "HEAD:f")
            let head = try await revParse(repo, "HEAD")

            #expect(try await reader.read(":f") == nil)
            #expect(try await reader.read(":0:f") == nil)
            #expect(try await reader.read("\(head.prefix(7)):f") == nil)
            #expect(try await reader.read("main:f") == nil)
            #expect(served(try await reader.attemptShow(":f", limit: nil)) == nil)

            // Staging a change is visible at once, as with git show.
            try Data("staged\n".utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "f")))
            _ = try await Dugite.exec(["add", "f"], repo.path)
            #expect(try await getBlobContents(repo, "", "f") == Data("staged\n".utf8))
        }

        @Test("accepts full object IDs and HEAD with ancestry steps")
        func freshNames() {
            let sha = String(repeating: "a", count: 40)
            for name in ["HEAD", "HEAD:f", "HEAD^:f", "HEAD~2^2:dir/f", sha, "\(sha):f", "\(sha)^:f", "\(sha.uppercased()):f"] {
                #expect(GitObjectReader.isFreshName(name, objectIDLength: 40), "\(name)")
            }
            for name in [":f", ":2:f", "main:f", "HEADS:f", "\(sha.prefix(39)):f", "\(sha)a:f", "HEAD@{1}:f", "HEAD^{tree}:f", "HEAD:a\nb", "HEAD:a\rb", "HEAD:a\u{0}b", "@:f"] {
                #expect(!GitObjectReader.isFreshName(name, objectIDLength: 40), "\(name)")
            }
            #expect(!GitObjectReader.isFreshName("\(sha):f", objectIDLength: 64))
        }
    }

    // The waits for the reader's events have no deadline of their own.
    @Suite("process", .hangGuard(minutes: 5))
    struct Process {
        @Test("serves concurrent requests in order from one process")
        func concurrentRequests() async throws {
            let repo = try setupEmptyRepository()
            let count = 64
            try await commitFiles(repo, (0..<count).map {
                (path: "file-\($0).txt", contents: Data(String(repeating: "\($0) ", count: $0 * 50 + 1).utf8))
            })
            let reader = GitObjectReader(repositoryPath: repo.path)

            let results = try await withThrowingTaskGroup(of: (Int, GitObjectReader.Response?).self) { group in
                for index in 0..<count {
                    group.addTask {
                        (index, try await reader.read("HEAD:file-\(index).txt"))
                    }
                }
                var results: [Int: GitObjectReader.Response?] = [:]
                for try await (index, response) in group {
                    results[index] = response
                }
                return results
            }

            for index in 0..<count {
                guard case .object(let object)?? = results[index] else {
                    Issue.record("No object for file-\(index).txt")
                    continue
                }
                #expect(object.type == "blob")
                #expect(object.contents == Data(String(repeating: "\(index) ", count: index * 50 + 1).utf8))
            }
            #expect(await reader.processesStarted == 1)
            await reader.shutDown()
        }

        @Test("a request cancelled while waiting for git leaves the next request in sync")
        func cancellationWhileWaiting() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [
                TreeEntry(path: "a.txt", contents: "a\n"),
                TreeEntry(path: "b.txt", contents: "b\n"),
            ]))
            let reader = GitObjectReader(repositoryPath: repo.path)
            _ = try await reader.read("HEAD:a.txt")
            let pid = try #require(await reader.processIdentifier)
            var events = await readerEvents(of: reader)

            // A stopped cat-file reads the request but never answers it.
            kill(pid, SIGSTOP)
            let request = Task { try await reader.read("HEAD:a.txt") }
            await wait(for: .awaitingResponse, in: &events)
            request.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await request.value
            }

            // The stopped process was discarded; its answer can't reach the next request.
            #expect(await processIsGone(pid))
            guard case .object(let object)? = try await reader.read("HEAD:b.txt") else {
                Issue.record("Expected b.txt")
                return
            }
            #expect(object.contents == Data("b\n".utf8))
            #expect(await reader.processesStarted == 2)
            await reader.shutDown()
        }

        @Test("a request cancelled while queued doesn't disturb the one in progress")
        func cancellationWhileQueued() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [
                TreeEntry(path: "a.txt", contents: "a\n"),
                TreeEntry(path: "b.txt", contents: "b\n"),
            ]))
            let reader = GitObjectReader(repositoryPath: repo.path)
            _ = try await reader.read("HEAD:a.txt")
            let pid = try #require(await reader.processIdentifier)
            var events = await readerEvents(of: reader)

            // The first request waits on a stopped cat-file, so the second
            // one is queued behind it when it's cancelled.
            kill(pid, SIGSTOP)
            let first = Task { try await reader.read("HEAD:a.txt") }
            await wait(for: .awaitingResponse, in: &events)
            let second = Task { try await reader.read("HEAD:b.txt") }
            await wait(for: .queued, in: &events)
            second.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await second.value
            }
            kill(pid, SIGCONT)
            guard case .object(let object)? = try await first.value else {
                Issue.record("Expected a.txt")
                return
            }
            #expect(object.contents == Data("a\n".utf8))
            #expect(await reader.processesStarted == 1)
            await reader.shutDown()
        }

        @Test("a request cancelled mid-object leaves the next request in sync")
        func cancellationMidObject() async throws {
            let repo = try setupEmptyRepository()
            let large = pseudoRandomBytes(count: 16 * 1024 * 1024, seed: 5)
            try await makeCommit(repo, Tree(entries: [
                TreeEntry(path: "large.bin", contents: large),
                TreeEntry(path: "small.txt", contents: "small\n"),
            ]))
            let reader = GitObjectReader(repositoryPath: repo.path)
            _ = try await reader.read("HEAD:small.txt")

            for delay in [1, 3, 10] {
                let request = Task { try await reader.read("HEAD:large.bin") }
                try await Task.sleep(for: .milliseconds(delay))
                request.cancel()
                switch await request.result {
                case .success(let response):
                    // Finished before the cancellation: it must be whole.
                    guard case .object(let object)? = response else {
                        Issue.record("Expected large.bin, got \(String(describing: response))")
                        continue
                    }
                    #expect(object.contents == large)
                case .failure(let error):
                    #expect(error is CancellationError)
                }

                guard case .object(let object)? = try await reader.read("HEAD:small.txt") else {
                    Issue.record("Expected small.txt")
                    continue
                }
                #expect(object.contents == Data("small\n".utf8))
            }
            await reader.shutDown()
        }

        @Test("a process that dies between requests is restarted")
        func deathBetweenRequests() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "f", contents: "f\n")]))
            let reader = GitObjectReader(repositoryPath: repo.path)

            _ = try await reader.read("HEAD:f")
            let pid = try #require(await reader.processIdentifier)
            kill(pid, SIGKILL)
            #expect(await processIsGone(pid))

            guard case .object(let object)? = try await reader.read("HEAD:f") else {
                Issue.record("Expected f")
                return
            }
            #expect(object.contents == Data("f\n".utf8))
            #expect(await reader.processesStarted == 2)
            #expect(await reader.processIdentifier != pid)
            await reader.shutDown()
        }

        @Test("a process that dies during a request is restarted and the request answered")
        func deathDuringRequest() async throws {
            let repo = try setupEmptyRepository()
            try await makeCommit(repo, Tree(entries: [TreeEntry(path: "f", contents: "f\n")]))
            let reader = GitObjectReader(repositoryPath: repo.path)

            _ = try await reader.read("HEAD:f")
            let pid = try #require(await reader.processIdentifier)
            var events = await readerEvents(of: reader)
            kill(pid, SIGSTOP)
            let request = Task { try await reader.read("HEAD:f") }
            await wait(for: .awaitingResponse, in: &events)
            kill(pid, SIGKILL)

            guard case .object(let object)? = try await request.value else {
                Issue.record("Expected f")
                return
            }
            #expect(object.contents == Data("f\n".utf8))
            #expect(await reader.processesStarted == 2)
            await reader.shutDown()
        }

        @Test("getBlobContents falls back to git show when a new process dies before answering")
        func deathOfNewProcessFallsBack() async throws {
            let repo = try setupEmptyRepository()
            let blob = pseudoRandomBytes(count: 1024 * 1024, seed: 9)
            try await makeCommit(repo, Tree(entries: [
                TreeEntry(path: "blob.bin", contents: blob),
                TreeEntry(path: "small.txt", contents: "small\n"),
            ]))
            let reader = GitObjectReader.shared(for: repo)
            // Validates with git show, without starting cat-file.
            try await validate(reader, repo, "HEAD:small.txt")
            #expect(await reader.processIdentifier == nil)

            // Kill the cat-file the read starts as it starts, before the read
            // sends it anything. A new process isn't retried, so the read
            // falls back to git show.
            let killed = FirstProcess()
            await reader.observeEvents { event in
                if case .started(let pid) = event, killed.claim(pid) {
                    kill(pid, SIGKILL)
                }
            }
            #expect(try await getBlobContents(repo, "HEAD", "blob.bin") == blob)
            #expect(killed.processIdentifier != nil)
            #expect(await reader.processesStarted == 1)

            // The next read starts a new process and is served by it.
            #expect(served(try await reader.attemptShow("HEAD:small.txt", limit: nil)) == Data("small\n".utf8))
            #expect(await reader.processesStarted == 2)
        }

        @Test("a path that isn't a repository is never served")
        func notARepository() async throws {
            let directory = try createTempDirectory()
            let reader = GitObjectReader(repositoryPath: directory)
            #expect(try await reader.read("HEAD:f") == nil)
            #expect(await reader.processesStarted == 0)

            let repo = Repository(path: directory)
            expectSame(await blobContents(repo, "HEAD", "f"), await desktopBlobContents(repo, "HEAD:f"))
        }
    }
}

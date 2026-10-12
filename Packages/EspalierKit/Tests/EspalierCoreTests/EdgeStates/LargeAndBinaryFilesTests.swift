// Large and binary files end to end through the models: a binary file, an
// image, a file git takes for binary because of a NUL byte,
// `.gitattributes` `binary` and a `diff=` driver with a textconv, a 100 MB
// file, a 10,000,000-line change and the "diff too large" path, with the
// main actor's longest stall measured while they load.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: large and binary files", .offline, .hangGuard(minutes: 10)) @MainActor
struct LargeAndBinaryFilesTests {
    /// A one-pixel PNG.
    private static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private func writeData(_ fixture: ChangesFixture, _ path: String, _ data: Data) throws {
        try data.write(to: URL(filePath: POSIXPath.join(fixture.local.path, path)))
    }

    @Test("binary files, an image, a NUL byte, and .gitattributes binary diff as binary or image, in Changes and History")
    func binaryKinds() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write(".gitattributes", "*.dat binary\n")
        try writeData(fixture, "random.bin", Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 7919) }))
        try writeData(fixture, "pixel.png", Self.png)
        try writeData(fixture, "nul.txt", Data("text\0with a NUL byte\n".utf8))
        try fixture.write("marked.dat", "plain text, marked binary\n")
        await fixture.refresh()

        try await fixture.select("random.bin")
        #expect(fixture.changes.diff == .loaded(.binary))
        #expect(!fixture.changes.canSelectLines)
        try await fixture.select("nul.txt")
        #expect(fixture.changes.diff == .loaded(.binary))
        try await fixture.select("marked.dat")
        #expect(fixture.changes.diff == .loaded(.binary))
        try await fixture.select("pixel.png")
        guard case .loaded(.image(let image)) = fixture.changes.diff else {
            Issue.record("Expected an image diff, not \(fixture.changes.diff)")
            return
        }
        #expect(image.previous == nil)
        #expect(image.current?.rawContents == Self.png)

        fixture.changes.setIncludeAll(true)
        let commit = try await fixture.commitIncluded("Binary files")
        #expect(fixture.paths.isEmpty)
        await fixture.activateHistory()
        fixture.history.select(shas: [commit.sha], contiguous: true)
        await fixture.settleHistory()
        let files = try #require(fixture.history.selection.changeset.value?.files)
        for (path, expected) in [("random.bin", DiffType.binary), ("nul.txt", .binary), ("marked.dat", .binary), ("pixel.png", .image)] {
            let file = try #require(files.first { $0.path == path })
            fixture.history.selectFile(file)
            await fixture.settleHistory()
            #expect(fixture.history.selection.diff.value?.kind == expected, "\(path)")
        }
    }

    @Test("a diff= driver's textconv shows in the diff, but its lines can't be committed alone, which would commit the converted text")
    func textconvDriver() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write(".gitattributes", "*.up diff=upper\n")
        try await fixture.git(["config", "diff.upper.textconv", "tr a-z A-Z <"])
        try fixture.write("notes.up", "one\ntwo\nthree\n")
        await fixture.refresh()

        // Shown converted, as git diff shows it.
        try await fixture.select("notes.up")
        #expect(addedLines(try fixture.shownText()) == ["ONE", "TWO", "THREE"])
        #expect(!fixture.changes.canSelectLines)

        // A partial selection made anyway isn't committed: it would commit
        // "TWO\nTHREE\n", the converted text.
        let file = try fixture.file("notes.up")
        fixture.changes.setLineSelection(file.selection.withSelectableLines([1, 2, 3]).withLineSelection(1, selected: false), forFile: file.id)
        fixture.commit.draft.summary = "Partial notes"
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.commit()
        }
        #expect(error?.message == textConvertedMessage("notes.up", "committed"))
        #expect(try await fixture.commitCount() == 1)

        // The whole file commits as it is.
        fixture.changes.setIncluded([file.id], true)
        _ = try await fixture.commitIncluded("Notes")
        #expect(try await fixture.git(["show", "HEAD:notes.up"]) == "one\ntwo\nthree\n")

        // Modified, the same: shown converted, no lines alone, and a line
        // can't be discarded.
        try fixture.write("notes.up", "one\ntwo, edited\nthree\n")
        await fixture.refresh()
        try await fixture.select("notes.up")
        #expect(addedLines(try fixture.shownText()) == ["TWO, EDITED"])
        #expect(!fixture.changes.canSelectLines)
        let added = try fixture.lineIndex(.add, "TWO, EDITED")
        let discardError = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.line(added), confirmed: [.discardLines])
        }
        #expect(discardError?.reason == .precondition(textConvertedMessage("notes.up", "discarded")))
        #expect(fixture.read("notes.up") == "one\ntwo, edited\nthree\n")

        // Without the driver, lines are selectable again.
        try await fixture.git(["config", "--unset", "diff.upper.textconv"])
        await fixture.refresh()
        try await fixture.select("notes.up")
        #expect(addedLines(try fixture.shownText()) == ["two, edited"])
        #expect(fixture.changes.canSelectLines)
    }

    @Test("a line over 5,000 characters or a diff over 4.4 MB is a large text diff; it still commits whole")
    func largeTextDiff() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try fixture.write("long-line.txt", String(repeating: "x", count: 6_000) + "\n")
        try fixture.write("many-lines.txt", (1...80_000).map { "line \($0) of a long file, padded to about eighty bytes........." }.joined(separator: "\n") + "\n")
        await fixture.refresh()

        try await fixture.select("long-line.txt")
        #expect(fixture.changes.diff.value?.kind == .largeText)
        try await fixture.select("many-lines.txt")
        #expect(fixture.changes.diff.value?.kind == .largeText)

        fixture.changes.setIncludeAll(true)
        _ = try await fixture.commitIncluded("Large files")
        #expect(fixture.paths.isEmpty)
        #expect((Int(JSCompat.trim(try await fixture.git(["cat-file", "-s", "HEAD:many-lines.txt"]))) ?? 0) > 4_375_000)
    }
}

/// The longest the main thread went without running a timer that fires every
/// 5 ms on it: how long the main actor was blocked.
@MainActor
final class MainThreadStallMonitor {
    private var timer: DispatchSourceTimer?
    private var last = ContinuousClock.now
    private(set) var longestGap = Duration.zero

    func start() {
        last = .now
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                let now = ContinuousClock.now
                self.longestGap = max(self.longestGap, now - self.last)
                self.last = now
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Opt-in, because the numbers only mean something on a quiet machine and
/// the files are large (about 130 MB):
///
///     ESPALIER_EDGE_PERF=1 swift test -c release --filter LargeFilePerformanceTests
@Suite(
    "Edge states: large file performance",
    .offline,
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ESPALIER_EDGE_PERF"] != nil)
) @MainActor
struct LargeFilePerformanceTests {
    private func measure(_ name: String, _ body: () async throws -> Void) async rethrows {
        let monitor = MainThreadStallMonitor()
        monitor.start()
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        monitor.stop()
        print("PERF \(name): \(elapsed), longest main-thread stall \(monitor.longestGap)")
        // A frame or two at 60 Hz; the work itself runs off the main actor.
        #expect(monitor.longestGap < .milliseconds(100), "\(name)")
    }

    @Test("a 10,000,000-line change and a 100 MB file load and commit without stalling the main thread")
    func hugeFiles() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        var lines = Data(repeating: UInt8(ascii: "\n"), count: 20_000_000)
        lines.withUnsafeMutableBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                bytes[index] = UInt8(ascii: "x")
            }
        }
        try lines.write(to: URL(filePath: POSIXPath.join(fixture.local.path, "ten-million-lines.txt")))
        var big = Data(capacity: 100_000_000)
        let row = Data((String(repeating: "0123456789", count: 9) + "abcdefghi\n").utf8)
        for _ in 0..<1_000_000 {
            big.append(row)
        }
        try big.write(to: URL(filePath: POSIXPath.join(fixture.local.path, "hundred-megabytes.txt")))

        await measure("status with both") {
            await fixture.refresh()
        }
        #expect(Set(fixture.paths) == ["ten-million-lines.txt", "hundred-megabytes.txt"])
        try await measure("10,000,000-line diff") {
            try await fixture.select("ten-million-lines.txt")
        }
        print("PERF 10,000,000-line diff kind: \(String(describing: fixture.changes.diff.value?.kind))")
        await measure("status and the diff again, with the 10,000,000-line diff shown") {
            try? fixture.write("small.txt", "small\n")
            await fixture.refresh()
        }
        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "small.txt"))
        await fixture.refresh()
        try await measure("100 MB diff") {
            try await fixture.select("hundred-megabytes.txt")
        }
        #expect(fixture.changes.diff.value?.kind == .unrenderable)
        fixture.changes.setIncludeAll(true)
        try await measure("committing both") {
            _ = try await fixture.commitIncluded("Huge files")
        }
        #expect(fixture.paths.isEmpty)
        await measure("History of the commit") {
            await fixture.activateHistory()
            let head = try? await fixture.head()
            fixture.history.select(shas: [head ?? ""], contiguous: true)
            await fixture.settleHistory()
        }
        let files = fixture.history.selection.changeset.value?.files ?? []
        #expect(files.count == 2)
        if let file = files.first(where: { $0.path == "ten-million-lines.txt" }) {
            await measure("History's 10,000,000-line diff") {
                fixture.history.selectFile(file)
                await fixture.settleHistory()
            }
        }
    }
}

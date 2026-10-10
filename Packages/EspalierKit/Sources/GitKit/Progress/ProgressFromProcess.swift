// Ported from desktop/app/src/lib/progress/from-process.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "progress")

/// Merges an instance of `GitExecutionOptions` with a process callback that
/// reads git's progress from its standard error, and Git LFS's progress from
/// the file named by `GIT_LFS_PROGRESS` when the options track LFS progress,
/// and reports it through `progressCallback`.
///
/// If the given options object already has a `processCallback` specified it
/// will be overwritten.
///
/// `progressCallback` is called on a background thread, one call at a time,
/// and every call has returned before the git call using these options does.
public func executionOptionsWithProgress(
    _ options: GitExecutionOptions,
    _ parser: some GitProgressParsing,
    _ progressCallback: @escaping @Sendable (GitProgressResult) -> Void
) async -> GitExecutionOptions {
    var lfsProgressPath: String?
    var env: [String: String?] = [:]
    if options.trackLFSProgress {
        do {
            let path = try await createLFSProgressFile()
            lfsProgressPath = path
            env["GIT_LFS_PROGRESS"] = path
        } catch {
            logger.error("Error writing LFS progress file: \(error.localizedDescription, privacy: .public)")
            // Unset: Git LFS would take any value as the name of a file to
            // write its progress to.
            env.updateValue(nil, forKey: "GIT_LFS_PROGRESS")
        }
    }

    var merged = options
    merged.processCallback = createProgressProcessCallback(parser, lfsProgressPath, progressCallback)
    merged.env = (options.env ?? [:]).merging(env) { $1 }
    return merged
}

/// Returns a callback which can be passed along to the `processCallback`
/// option in `GitExecutionOptions`. The callback then takes care of reading
/// stderr of the process and parsing its contents using the provided parser.
private func createProgressProcessCallback(
    _ parser: some GitProgressParsing,
    _ lfsProgressPath: String?,
    _ progressCallback: @escaping @Sendable (GitProgressResult) -> Void
) -> @Sendable (ChildProcess) -> Void {
    // Shared by every process these options start.
    let parser = SharedProgressParser(parser)

    return { process in
        let reader = ProgressProcessReader(
            parse: { parser.parse($0) },
            progressCallback: progressCallback
        )

        let lfsTail = lfsProgressPath.map { path in
            tailByLine(path) { line in
                reader.receiveLFSLine(line)
            }
        }

        process.observeStandardError { chunk in
            reader.receiveStandardError(chunk)
        }

        process.onClose {
            reader.finishStandardError()

            if let lfsProgressPath {
                lfsTail?.dispose()
                // We don't want to surface errors to the user if something
                // goes wrong (the file can stay in TMPDIR and be cleaned up
                // eventually).
                unlink(lfsProgressPath)
            }
        }
    }
}

/// A parser shared by the processes of one set of execution options.
private final class SharedProgressParser<Parser: GitProgressParsing>: Sendable {
    private let parser: Mutex<Parser>

    init(_ parser: Parser) {
        self.parser = Mutex(parser)
    }

    func parse(_ line: String) -> GitProgressResult {
        parser.withLock { $0.parse(line) }
    }
}

/// Reads the progress of one git process: its standard error, line by line,
/// and the lines of the Git LFS progress file.
///
/// Standard error and the LFS progress file arrive on different threads, so
/// a lock serializes them, and each progress callback runs while it is held.
private final class ProgressProcessReader: Sendable {
    private struct State {
        var lfsProgressActive = false
        var lines = LineSplitter()
        var lfsParser = GitLFSProgressParser()
    }

    private let state = Mutex(State())
    private let parse: @Sendable (String) -> GitProgressResult
    private let progressCallback: @Sendable (GitProgressResult) -> Void

    init(
        parse: @escaping @Sendable (String) -> GitProgressResult,
        progressCallback: @escaping @Sendable (GitProgressResult) -> Void
    ) {
        self.parse = parse
        self.progressCallback = progressCallback
    }

    func receiveStandardError(_ chunk: Data) {
        state.withLock { state in
            for line in state.lines.push(chunk) {
                handleLine(line, &state)
            }
        }
    }

    func finishStandardError() {
        state.withLock { state in
            for line in state.lines.finish() {
                handleLine(line, &state)
            }
        }
    }

    func receiveLFSLine(_ line: String) {
        state.withLock { state in
            let progress = state.lfsParser.parse(line)

            if case .progress = progress {
                state.lfsProgressActive = true
                progressCallback(progress)
            }
        }
    }

    private func handleLine(_ line: String, _ state: inout State) {
        let progress = parse(line)

        if state.lfsProgressActive {
            // While we're sending LFS progress we don't want to mix
            // any non-progress events in with the output or we'll get
            // flickering between the indeterminate LFS progress and
            // the regular progress.
            guard case .progress(let gitProgress) = progress else {
                return
            }

            // The 'Filtering content' title happens while the LFS
            // filter is running and when it's done we know that the
            // filter is done but until then we don't want to display
            // it for the same reason that we don't want to display
            // the context above.
            if JSCompat.strictEquals(gitProgress.details.title, "Filtering content") {
                if gitProgress.details.done {
                    state.lfsProgressActive = false
                }
                return
            }
        }

        progressCallback(progress)
    }
}

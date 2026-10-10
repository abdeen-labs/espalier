// The lines each changed file adds and removes, which Changes shows on its
// rows ("+10 −2"). A read-only load after each status pass, in a
// `LatestTask` slot: the files show at once and their counts follow;
// GitKit's `getWorkingDirectoryLineCounts` counts them.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "changes")

extension ChangesModel {
    /// Past this many changed files no counts load at all: the same limit
    /// as the list's animated updates, and a list that long is read by name,
    /// not by its counts.
    public static let lineCountFileLimit = 1_000

    /// `file`'s lines added and removed, once loaded; nil while they load
    /// and for a file that has none (`lineCounts`).
    public func lineCount(of file: WorkingDirectoryFileChange) -> FileLineCount? {
        lineCounts[ExactString(file.id)]
    }

    /// Loads the files' line counts against `tip` (HEAD's commit as the
    /// status saw it; nil while HEAD is unborn), replacing the counts once
    /// they arrive. The counts shown meanwhile are the last pass's.
    ///
    /// Loads only while the repository is selected (status passes also run
    /// for the others' indicators); its selection's refresh loads them.
    /// With no files, or more than `lineCountFileLimit`, there are none. A
    /// load that's no longer the latest never applies; one that fails
    /// leaves no counts.
    func loadLineCounts(against tip: String?) {
        guard let repository, repository.isActive else {
            return
        }
        let files = workingDirectory.files
        guard !files.isEmpty, files.count <= Self.lineCountFileLimit else {
            lineCountLoads.cancel()
            if !lineCounts.isEmpty {
                lineCounts = [:]
            }
            return
        }

        lineCountSequence &+= 1
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let countLines = countLines
        lineCountLoads.run(lineCountSequence, operation: {
            try await environment.withRuntimes {
                try await countLines(gitRepository, files, tip)
            }
        }, apply: { [weak self] (result: Result<[ExactString: FileLineCount], any Error>) in
            guard let self else {
                return
            }
            switch result {
            case .success(let counts):
                if counts != self.lineCounts {
                    self.lineCounts = counts
                }
            case .failure(let error):
                if error is CancellationError {
                    return
                }
                logger.error("Could not count the changed lines: \(error.localizedDescription, privacy: .public)")
                if !self.lineCounts.isEmpty {
                    self.lineCounts = [:]
                }
            }
        })
    }

    /// Waits for the line count load in flight (for tests and `idle()`).
    func lineCountsIdle() async {
        await lineCountLoads.idle()
    }
}

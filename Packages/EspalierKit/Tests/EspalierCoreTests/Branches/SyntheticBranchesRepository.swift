// A large synthetic repository for the upstream states' performance test
// (UpstreamStatesPerformanceTests.swift), built with `git fast-import` so it
// takes seconds, not minutes.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// A repository with a long history and thousands of local branches, each
/// tracking a remote-tracking branch it has diverged from.
struct SyntheticBranchesRepository {
    let repository: Repository
    /// The local branches, by name (`b0`, `b1`, ...), in creation order.
    let branchNames: [String]
    /// How many commits the repository has.
    let commitCount: Int

    /// Builds the repository in a temporary directory.
    ///
    /// The history is a first-parent line of `mainline` commits; every
    /// tenth one merges a side line of three to seven commits that forked
    /// 150 commits earlier, so about fifteen lines are open at any point
    /// and a walk between two commits has a wide frontier. Branch `bN`
    /// starts at a mainline commit and adds up to three commits of its own
    /// (ahead); its upstream `origin/bN` is a later mainline commit (behind
    /// by up to 60 mainline commits and the side lines merged in between,
    /// every 25th branch by 1,000 to 3,000), every third one with a commit
    /// of its own. Refs are written packed, as clone and gc leave them, and
    /// there's no commit-graph.
    static func make(mainline: Int = 30_000, branches: Int = 5_000) async throws -> SyntheticBranchesRepository {
        let path = POSIXPath.join(try createTempDirectory(), "synthetic")
        let initResult = try await Dugite.exec(["init", "--quiet", "-b", "main", path], try createTempDirectory())
        try #require(initResult.exitCode == 0)
        let repository = Repository(path: path)

        var stream = ""
        stream.reserveCapacity(16 << 20)
        var mark = 0
        var time = 1_500_000_000
        func commit(_ parents: [Int], _ message: String) -> Int {
            mark += 1
            time += 1
            stream += "commit refs/heads/main\nmark :\(mark)\ncommitter A U Thor <author@example.com> \(time) +0000\ndata \(message.utf8.count)\n\(message)\n"
            if let first = parents.first {
                stream += "from :\(first)\n"
            } else {
                stream += "M 644 inline README\ndata 7\nREADME\n"
            }
            for parent in parents.dropFirst() {
                stream += "merge :\(parent)\n"
            }
            stream += "\n"
            return mark
        }

        var main: [Int] = []
        main.reserveCapacity(mainline)
        for index in 0..<mainline {
            if index % 10 == 9, index >= 160 {
                var side = main[index - 150]
                for step in 0..<(3 + index % 5) {
                    side = commit([side], "side \(index) \(step)")
                }
                main.append(commit([main[index - 1], side], "merge \(index)"))
            } else {
                main.append(commit(index == 0 ? [] : [main[index - 1]], "main \(index)"))
            }
        }

        var localMarks: [Int] = []
        var upstreamMarks: [Int] = []
        let span = mainline - 3_200
        for branch in 0..<branches {
            let baseIndex = 100 + (branch &* 7_919) % span
            var tip = main[baseIndex]
            for step in 0..<(branch % 4) {
                tip = commit([tip], "local \(branch) \(step)")
            }
            let behind = branch % 25 == 0 ? 1_000 + (branch * 37) % 2_000 : branch % 61
            var upstream = main[baseIndex + behind]
            if branch % 3 == 0 {
                upstream = commit([upstream], "remote \(branch)")
            }
            localMarks.append(tip)
            upstreamMarks.append(upstream)
        }
        let mainTip = main[mainline - 1]

        let marksPath = POSIXPath.join(try createTempDirectory(), "marks")
        let imported = try await Dugite.exec(
            ["fast-import", "--quiet", "--export-marks=\(marksPath)"],
            path,
            options: Dugite.ExecutionOptions(stdin: Data(stream.utf8))
        )
        try #require(imported.exitCode == 0, "\(String(decoding: imported.stderr, as: UTF8.self))")

        // The marks file has a line ":<mark> <sha>" for each commit.
        var shas = [String](repeating: "", count: mark + 1)
        for line in try String(contentsOfFile: marksPath, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let number = Int(parts[0].dropFirst()) {
                shas[number] = String(parts[1])
            }
        }

        // Every ref packed, sorted by name, as `git pack-refs` writes them.
        var refs: [(name: String, sha: String)] = [("refs/heads/main", shas[mainTip]), ("refs/remotes/origin/main", shas[mainTip])]
        var names: [String] = []
        var config = "[remote \"origin\"]\n\turl = https://example.com/synthetic.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        config += "[branch \"main\"]\n\tremote = origin\n\tmerge = refs/heads/main\n"
        for branch in 0..<branches {
            let name = "b\(branch)"
            names.append(name)
            refs.append(("refs/heads/\(name)", shas[localMarks[branch]]))
            refs.append(("refs/remotes/origin/\(name)", shas[upstreamMarks[branch]]))
            config += "[branch \"\(name)\"]\n\tremote = origin\n\tmerge = refs/heads/\(name)\n"
        }
        refs.sort { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        let packed = "# pack-refs with: peeled fully-peeled sorted \n" + refs.map { "\($0.sha) \($0.name)\n" }.joined()
        let gitDirectory = POSIXPath.join(path, ".git")
        try Data(packed.utf8).write(to: URL(filePath: POSIXPath.join(gitDirectory, "packed-refs")))
        try? FileManager.default.removeItem(atPath: POSIXPath.join(gitDirectory, "refs/heads/main"))
        let handle = try FileHandle(forWritingTo: URL(filePath: POSIXPath.join(gitDirectory, "config")))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(config.utf8))
        try handle.close()

        let reset = try await Dugite.exec(["reset", "--hard", "--quiet"], path)
        try #require(reset.exitCode == 0, "\(String(decoding: reset.stderr, as: UTF8.self))")
        return SyntheticBranchesRepository(repository: repository, branchNames: names, commitCount: mark)
    }
}

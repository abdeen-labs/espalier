import Foundation
import GitKit
import Testing
import TestSupport

@Suite("pathExists")
struct PathExistsTests {
    @Test("finds files and directories, and follows symbolic links")
    func existence() async throws {
        let directory = try createTempDirectory()
        let file = "\(directory)/file"
        try Data().write(to: URL(filePath: file))
        try FileManager.default.createSymbolicLink(atPath: "\(directory)/link", withDestinationPath: file)
        try FileManager.default.createSymbolicLink(atPath: "\(directory)/dangling", withDestinationPath: "\(directory)/missing")

        #expect(await pathExists(directory))
        #expect(await pathExists(file))
        #expect(await pathExists("\(directory)/link"))
        #expect(await !pathExists("\(directory)/missing"))
        #expect(await !pathExists("\(directory)/dangling"))
    }
}

// The last fetch's date as the refresher reads it from FETCH_HEAD.

@testable import EspalierCore
import EspalierSupport
import Foundation
import Testing
import TestSupport

@Suite("FETCH_HEAD date")
struct FetchHeadDateTests {
    @Test("is absent when the repository was never fetched")
    func missing() async throws {
        let gitDir = try createTempDirectory()
        let date = await fetchHeadDate(gitDir)
        #expect(date == .some(nil))
    }

    @Test("keeps the previous date when FETCH_HEAD is empty, as after a failed fetch")
    func empty() async throws {
        let gitDir = try createTempDirectory()
        try Data().write(to: URL(filePath: POSIXPath.join(gitDir, "FETCH_HEAD")))
        let date = await fetchHeadDate(gitDir)
        #expect(date == .none)
    }

    @Test("is FETCH_HEAD's modification date")
    func modified() async throws {
        let gitDir = try createTempDirectory()
        let path = POSIXPath.join(gitDir, "FETCH_HEAD")
        try Data("a1b2c3d\t\tbranch 'main' of origin\n".utf8).write(to: URL(filePath: path))
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        let date = await fetchHeadDate(gitDir)
        #expect(date == .some(modified))
    }
}

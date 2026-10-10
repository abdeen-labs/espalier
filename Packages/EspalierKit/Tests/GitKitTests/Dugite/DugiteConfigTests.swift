// Ported from dugite/test/fast/config-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing

@Suite("config")
struct DugiteConfigTests {
    // "sets http.sslBackend on Windows" and "unsets http.sslCAInfo on Windows"
    // are left out: they only check Windows' bundled configuration.

    // This runs in a temporary directory: the tests' `HOME` is empty, and
    // `--system` doesn't depend on the working directory.

    @Test("uses the custom system config from desktop's git build")
    func usesTheBuildsCustomSystemConfig() async throws {
        let directory = try createTestDir("desktop-git-test-config")
        let result = try await Dugite.exec(
            ["config", "--show-origin", "--system", "include.path"],
            directory
        )
        let parts = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        let origin = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : nil

        let originPath = String(origin.dropFirst("file:".count))

        #expect(
            POSIXPath.resolve(originPath)
                == POSIXPath.join(Dugite.resolveGitDir().path(percentEncoded: false), "etc", "gitconfig")
        )

        #expect(value == "/etc/gitconfig")
    }
}

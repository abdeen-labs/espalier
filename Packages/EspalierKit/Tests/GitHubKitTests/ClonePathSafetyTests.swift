// Ported from desktop/app/test/unit/clone-path-safety-test.ts

import EspalierSupport
@testable import GitHubKit
import Testing

@Suite("sanitizeCloneName")
struct SanitizeCloneNameTests {
    @Test("returns a simple name unchanged")
    func returnsSimpleName() {
        #expect(sanitizeCloneName("Hello-World") == "Hello-World")
    }

    @Test("extracts last component from backslash-separated traversal")
    func extractsLastComponent() {
        #expect(sanitizeCloneName(#"x..\..\..\..\foo"#) == "foo")
    }

    @Test("rejects names that resolve to .. or empty")
    func rejectsTraversalNames() {
        #expect(sanitizeCloneName("..") == nil)
        #expect(sanitizeCloneName("") == nil)
        #expect(sanitizeCloneName(".git") == nil)
    }

    @Test(#"does not traverse from default basepath (#x\..\..\..\.ssh)"#)
    func doesNotTraverse() {
        #expect(sanitizeCloneName(#"x..\..\..\../.ssh"#) == ".ssh")
    }
}

@Suite("clone path derivation with sanitizeCloneName")
struct ClonePathDerivationTests {
    @Test("normal URLs are unchanged after sanitization")
    func normalURLsUnchanged() throws {
        let urls = [
            "https://github.com/octocat/Hello-World.git",
            "git@github.com:octocat/Hello-World.git",
            "octocat/Hello-World",
        ]
        for url in urls {
            let result = try #require(parseRepositoryIdentifier(url), "Failed to parse: \(url)")
            #expect(sanitizeCloneName(result.name) == "Hello-World")
        }
    }

    @Test("traversal payload clone path stays contained (POSIX)")
    func traversalStaysContained() throws {
        let result = try #require(parseRepositoryIdentifier(#"https://evil.com/owner/x..\..\..\.\.ssh.git"#))
        let safeName = try #require(sanitizeCloneName(result.name))
        let baseDir = "/Users/victim/Documents/GitHub"
        let resolved = POSIXPath.resolve(POSIXPath.join(baseDir, safeName))
        #expect(
            resolved.hasPrefix(POSIXPath.resolve(baseDir)),
            "Clone path \"\(resolved)\" escapes base dir"
        )
    }
}

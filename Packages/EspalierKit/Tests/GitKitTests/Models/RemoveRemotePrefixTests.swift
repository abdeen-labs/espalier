// Ported from desktop/app/test/unit/remove-remote-prefix-test.ts

import GitKit
import Testing
import TestSupport

@Suite("removeRemotePrefix")
struct RemoveRemotePrefixTests {
    @Test("removes the remote prefix, if there is one", arguments: [
        NamedCase("removes the remote prefix", (name: "origin/test", expected: "test")),
        NamedCase("removes only the remote prefix and not any subsequent /'s", (name: "origin/test/name", expected: "test/name")),
        NamedCase("returns null if there is no remote prefix", (name: "name", expected: nil)),
    ] as [NamedCase<(name: String, expected: String?)>])
    func removesRemotePrefix(_ testCase: NamedCase<(name: String, expected: String?)>) {
        #expect(removeRemotePrefix(testCase.value.name) == testCase.value.expected)
    }
}

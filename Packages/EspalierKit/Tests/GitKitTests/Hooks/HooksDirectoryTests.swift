import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("populateHooksDirectory")
struct HooksDirectoryTests {
    func write(_ path: String, _ text: String, mode: Int) throws {
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func destination(ofLink path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    @Test("links intercepted hooks to the proxy and exposes the others")
    func populates() throws {
        let hooks = try createTempDirectory()
        let directory = try createTempDirectory()
        try write(POSIXPath.join(hooks, "pre-commit"), "#!/bin/sh\n", mode: 0o755)
        try write(POSIXPath.join(hooks, "post-commit"), "#!/bin/sh\n", mode: 0o755)
        try write(POSIXPath.join(hooks, "commit-msg"), "#!/bin/sh\n", mode: 0o644)
        try write(POSIXPath.join(hooks, "pre-push.sample"), "#!/bin/sh\n", mode: 0o755)
        try write(POSIXPath.join(hooks, ".hidden"), "", mode: 0o755)
        try write(POSIXPath.join(hooks, "lib", "helper.sh"), "", mode: 0o755)
        try write(POSIXPath.join(hooks, "it's odd"), "#!/bin/sh\n", mode: 0o755)

        try populateHooksDirectory(directory, interceptedHooks: ["pre-commit"], proxyPath: "/proxy", repositoryHooksPath: hooks)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        #expect(names == ["commit-msg", "it's odd", "post-commit", "pre-commit"])
        #expect(destination(ofLink: POSIXPath.join(directory, "pre-commit")) == "/proxy")
        #expect(destination(ofLink: POSIXPath.join(directory, "commit-msg")) == POSIXPath.join(hooks, "commit-msg"))

        let wrapper = POSIXPath.join(directory, "post-commit")
        #expect(destination(ofLink: wrapper) == nil)
        #expect(try String(contentsOfFile: wrapper, encoding: .utf8).hasSuffix("exec '\(POSIXPath.join(hooks, "post-commit"))' \"$@\"\n"))
        #expect(access(wrapper, X_OK) == 0)
        #expect(try String(contentsOfFile: POSIXPath.join(directory, "it's odd"), encoding: .utf8).contains("exec '\(hooks)/it'\\''s odd' \"$@\""))
    }

    @Test("runs exposed hooks with their own path, arguments, input, and exit status")
    func wrappersRunHooks() async throws {
        let hooks = POSIXPath.join(try createTempDirectory(), "hooks with 'quotes'")
        let directory = try createTempDirectory()
        try write(POSIXPath.join(hooks, "post-rewrite"), """
            #!/bin/sh
            echo "$0|$1|$(cat)"
            exit 7
            """, mode: 0o755)

        try populateHooksDirectory(directory, interceptedHooks: [], proxyPath: "/proxy", repositoryHooksPath: hooks)

        let child = try ChildProcess(ChildProcess.Configuration(
            executableURL: URL(filePath: POSIXPath.join(directory, "post-rewrite")),
            arguments: ["amend"],
            environment: ["PATH": "/usr/bin:/bin"],
            pipesStandardInput: true
        ))
        let output = OutputCollector()
        child.observeStandardOutput { output.append($0) }
        child.startReading()
        try await child.writeToStandardInput(Data("old new".utf8))
        child.closeStandardInput()

        #expect(await child.waitUntilExit() == .exit(7))
        #expect(output.text == "\(POSIXPath.join(hooks, "post-rewrite"))|amend|old new\n")
    }

    @Test("follows symbolic links and skips what isn't a file")
    func symbolicLinks() throws {
        let root = try createTempDirectory()
        let hooks = POSIXPath.join(root, "hooks")
        let directory = try createTempDirectory()
        try write(POSIXPath.join(root, "scripts", "check"), "#!/bin/sh\n", mode: 0o755)
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(hooks, "pre-push"), withDestinationPath: "../scripts/check")
        try FileManager.default.createSymbolicLink(atPath: POSIXPath.join(hooks, "post-merge"), withDestinationPath: "../scripts/missing")
        try FileManager.default.createDirectory(atPath: POSIXPath.join(hooks, "post-checkout"), withIntermediateDirectories: false)

        try populateHooksDirectory(directory, interceptedHooks: [], proxyPath: "/proxy", repositoryHooksPath: hooks)

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["pre-push"])
    }

    @Test("does nothing more when the hooks directory doesn't exist")
    func missingHooksDirectory() throws {
        let directory = try createTempDirectory()
        try populateHooksDirectory(directory, interceptedHooks: ["pre-commit"], proxyPath: "/proxy", repositoryHooksPath: "/nonexistent/hooks")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["pre-commit"])
    }
}

import Synchronization

private final class OutputCollector: Sendable {
    private let data = Mutex(Data())

    func append(_ chunk: Data) {
        data.withLock { $0.append(chunk) }
    }

    var text: String {
        String(decoding: data.withLock { $0 }, as: UTF8.self)
    }
}

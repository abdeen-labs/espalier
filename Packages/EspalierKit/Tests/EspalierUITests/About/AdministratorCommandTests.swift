// The AppleScript string that carries a command to `do shell script` reads
// back as the command: osascript returns the literal's text, byte for byte.

import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Administrator commands") @MainActor
struct AdministratorCommandTests {
    @Test("an AppleScript string literal holds the text exactly", .hangGuard(minutes: 5), arguments: [
        NamedCase("plain text", "/bin/rm -rf '/Applications/Espalier.app'"),
        NamedCase("a double quote", #"say "hi""#),
        // As a `Character`, the quote and the mark are one, which a
        // `replacingOccurrences(of: "\"", ...)` misses.
        NamedCase("a double quote followed by a combining mark", "a\"\u{301}b"),
        NamedCase("a double quote followed by a combining mark, then AppleScript", "x\"\u{301} & (do shell script \"echo pwned\") & \""),
        NamedCase("a backslash", #"a\b"#),
        NamedCase("a backslash followed by a combining mark", "a\\\u{301}b"),
        NamedCase("a backslash before a double quote", #"a\"b"#),
        NamedCase("non-ASCII", "Espalier é 日本 🌳"),
    ])
    func appleScriptString(_ testCase: NamedCase<String>) async throws {
        let text = testCase.value
        let stdout = Mutex(Data())
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "return \(AdministratorCommand.appleScriptString(text))"],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        child.observeStandardOutput { chunk in stdout.withLock { $0.append(chunk) } }
        #expect(await child.waitUntilExit() == .exit(0))
        // osascript ends what it returns with a newline.
        #expect(stdout.withLock { $0 } == Data((text + "\n").utf8))
    }
}
